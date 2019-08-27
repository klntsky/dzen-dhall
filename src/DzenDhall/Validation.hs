-- | Functions for `config.dhall` validation.
module DzenDhall.Validation where

import           DzenDhall.Config
import           DzenDhall.Event
import           DzenDhall.Extra

import           Control.Monad
import           Data.Maybe
import           Data.Text (Text)
import           Data.Void
import           Lens.Micro
import           System.Directory (findExecutable)
import           System.Exit
import           System.Process
import           Text.Megaparsec hiding (Token, tokens)
import           Text.Megaparsec.Char
import qualified Data.HashMap.Strict as H
import qualified Data.Text


type ParseErrors = Text.Megaparsec.ParseErrorBundle String Void


data Error
  = InvalidAutomatonAddress ParseErrors Text
  | BinaryNotInPath Text Text
  | AssertionFailure Text Text
  | InvalidColor ParseErrors Text
  | InvalidHook


run :: [Token] -> IO ([Error], [Token])
run tokens = do
  let errors = validate tokens
  assertionErrors <- checkAssertions tokens
  pure $ (errors <> assertionErrors, filterOutAssertions tokens)


filterOutAssertions :: [Token] -> [Token]
filterOutAssertions = filter $ \case
  TokCheck _ -> False
  _          -> True


validate :: [Token] -> [Error]
validate = reverse . go []
  where
    go acc [] = acc
    go acc (TokOpen (OAutomaton address stt) : rest) =
      let sttErrors =
            (concat $ H.elems (unSTT stt) <&> (^. _2)) >>=
            \(hook :: Hook) -> [ InvalidHook | null (hook ^. hookCommand)  ]
      in
        go (proceed InvalidAutomatonAddress automatonAddressParser address
            (sttErrors <> acc)) rest
    go acc (TokOpen (OFG (Color color)) : rest) =
      go (proceed InvalidColor colorParser color acc) rest
    go acc (TokOpen (OBG (Color color)) : rest) =
      go (proceed InvalidColor colorParser color acc) rest
    go acc (_ : rest) =
      go acc rest

    proceed cont parser what acc =
      case getError parser (Data.Text.unpack what) of
        Nothing -> acc
        Just err -> cont err what : acc

    colorParser =
      (try (hex 6) <|> try (hex 3) <|> colorName) <* eof
      where
        hex :: Int -> Parser Text
        hex size = do
          void $ char '#'
          replicateM_ size hexDigitChar
          pure ""

        colorName = do
          void letterChar
          void $ many (alphaNumChar <|> spaceChar)
          pure ""


checkAssertions :: [Token] -> IO [Error]
checkAssertions [] = pure []
checkAssertions (TokCheck check : xs) = do
  newErrors <-
    case check ^. chAssertion of
      BinaryInPath binary -> do
        mbPath <- findExecutable (Data.Text.unpack binary)
        pure [ BinaryNotInPath binary (check ^. chMessage) | isNothing mbPath ]
      SuccessfulExit code -> do
        let process = shell (Data.Text.unpack code)
        (exitCode, _, _) <- readCreateProcessWithExitCode process ""
        pure [ AssertionFailure code (check ^. chMessage) | exitCode /= ExitSuccess ]

  (newErrors ++) <$> checkAssertions xs

checkAssertions (_ : xs) = checkAssertions xs

-- | Check if the input is parseable by the parser.
getError :: Text.Megaparsec.Parsec Void String Text -> String -> Maybe (Text.Megaparsec.ParseErrorBundle String Void)
getError parser =
  leftToJust . Text.Megaparsec.parse (parser *> Text.Megaparsec.eof) ""


-- | Pretty-print errors.
report :: [Error] -> Text
report [] = "No errors."
report errors = mappend header $ foldMap ((<> "\n\n") . reportError) errors
  where
    header = "Some errors encountered while trying to read the configuration:\n\n\n"

    namingConventions = "More info: https://github.com/dzen-dhall/dzen-dhall#naming-conventions"

    reportError :: Error -> Text
    reportError = \case

      InvalidAutomatonAddress err address -> fromLines
        [ "Invalid automaton address: " <> address
        , "Error: " <> Data.Text.pack (Text.Megaparsec.errorBundlePretty err)
        , namingConventions
        ]

      BinaryNotInPath binary message -> fromLines $
        [ "One of required binaries was not found in $PATH: " <> binary
        ] <>
        [ fromLines
          [ ""
          , "Message:"
          , ""
          , message
          ]
        | not (Data.Text.null message)
        ]

      AssertionFailure code message -> fromLines $
        [ "One of assertions failed:"
        , ""
        , code
        ] <>
        [ fromLines
          [ ""
          , "Message:"
          , ""
          , message
          ]
        | not (Data.Text.null message)
        ]

      InvalidColor err name -> fromLines
        [ "Invalid color value encountered: " <> name
        , "Error: " <> Data.Text.pack (Text.Megaparsec.errorBundlePretty err)
        ]

      InvalidHook ->
        "Detected a hook with empty command"
