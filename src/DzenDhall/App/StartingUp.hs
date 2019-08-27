module DzenDhall.App.StartingUp where

import           DzenDhall.AST
import           DzenDhall.App as App
import           DzenDhall.Arguments
import           DzenDhall.Config
import           DzenDhall.Data
import           DzenDhall.Extra
import           DzenDhall.Runtime.Data
import qualified DzenDhall.Animation.Marquee as Marquee
import qualified DzenDhall.Animation.Slider as Slider

import           Control.Arrow
import           Control.Applicative
import           Control.Monad
import           Data.IORef
import           Data.Maybe
import           Data.Text (Text)
import           GHC.IO.Handle
import           Lens.Micro
import           Lens.Micro.Extras
import           System.Environment
import           System.Posix.Files
import           System.Process
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified System.IO
import qualified Pipes.Prelude as P
import qualified Pipes as P


startUp
  :: Configuration
  -> Bar Marshalled
  -> App StartingUp (Bar Initialized, Subscriptions, BarRuntime, ClickableAreas)
startUp cfg bar = do
  barRuntime  <- mkBarRuntime cfg
  bar'        <- initialize bar

  state       <- get

  environment <- liftIO getEnvironment

  forM_ (state ^. ssSourceQueue) $
    \(source, outputRef, cacheRef, scope) -> do
      mkThread environment barRuntime source outputRef cacheRef scope

  forM_ (state ^. ssVariableDefinitions) $
    \(scope, name, value) -> do

      let fileName =
            state ^. ssVariableFilePrefix <>
            T.unpack scope <>
            "-v-" <>
            T.unpack name

      liftIO $ do
        T.writeFile fileName value
        setFileMode fileName $
          ownerReadMode  `unionFileModes`
          groupReadMode  `unionFileModes`
          ownerWriteMode `unionFileModes`
          groupWriteMode

  forM_ (H.toList $ state ^. ssImages) $
    \(imageContents, imageId) -> liftIO $ do
      T.writeFile
        (state ^. ssImagePathPrefix <> T.unpack imageId <> ".xbm") imageContents

  pure (bar', state ^. ssSubscriptions, barRuntime, state ^. ssClickableAreas)


mkBarRuntime
  :: Configuration
  -> App StartingUp BarRuntime
mkBarRuntime cfg = do
  runtime <- getRuntime
  state   <- get

  let dzenBinary  = runtime ^. rtDzenBinary
      barSettings = cfg ^. cfgBarSettings

      extraArgs  = barSettings ^. bsExtraArgs
      fontArgs   = maybe [] (\font -> ["-fn", font]) $ barSettings ^. bsFont
      args       = fontArgs <> extraArgs

      namedPipe          = state ^. ssNamedPipe
      emitterFile        = state ^. ssEmitterFile
      getterFile         = state ^. ssGetterFile
      setterFile         = state ^. ssSetterFile
      variableFilePrefix = state ^. ssVariableFilePrefix

  liftIO $
    createNamedPipe namedPipe (ownerReadMode `unionFileModes` ownerWriteMode)

  liftIO $ do
    forM_ [ ( [ "#!/usr/bin/env bash"
              , "SCOPE=\"$1\""
              , "EVENT=\"$2\""
              , "echo event:\"$EVENT\"@\"$SCOPE\" >> " <>
                T.pack namedPipe
              ],
              emitterFile
            )

          , ( [ "#!/usr/bin/env bash"
              , "SCOPE=\"$1\""
              , "VAR=\"$2\""
              , "cat \"" <> T.pack variableFilePrefix <> "$SCOPE-v-$VAR\""
              ]
            , getterFile
            )

          , ( [ "#!/usr/bin/env bash"
              , "SCOPE=\"$1\""
              , "VAR=\"$2\""
              , "VALUE=\"$3\""
              , "echo \"$VALUE\" > " <>
                T.pack variableFilePrefix <> "\"$SCOPE-v-$VAR\""
              ]
            , setterFile
            )
          ] $

      \(codeLines, file) -> do

        T.writeFile file $ fromLines codeLines
        setFileMode file $
          ownerExecuteMode `unionFileModes`
          groupExecuteMode `unionFileModes`
          ownerReadMode    `unionFileModes`
          groupReadMode

  handle <- case runtime ^. rtArguments ^. stdoutFlag of

    ToStdout -> pure System.IO.stdout

    ToDzen -> do
      (mb_stdin, _, _, _) <- liftIO $
        createProcess $
          (proc (runtime ^. rtDzenBinary) args)
            { std_out = CreatePipe
            , std_in  = CreatePipe }

      case mb_stdin of
        (Just stdin) -> liftIO $ do
          hSetEncoding  stdin  System.IO.utf8
          hSetBuffering stdin  LineBuffering
          pure stdin
        _ -> App.exit 4 $
          "Couldn't open IO handles for dzen binary " <>
          showPack dzenBinary

  pure $ BarRuntime cfg 0 namedPipe emitterFile getterFile setterFile handle


-- | During initialization, IORefs for source outputs and caches are created.
-- Also, new threads for each unique source is created. These threads then
-- update the outputs.
initialize
  :: Bar Marshalled
  -> App StartingUp (Bar Initialized)
initialize (BarSource source@Source{escape}) = do

  state <- get

  -- We don't want to spawn separate threads for identical `Source`s within
  -- the same scope.
  -- A HashMap is used to cache all references to sources and prevent
  -- duplication when possible.
  -- Note that identical sources from distinct scopes are intentionally allowed:
  -- we don't want separate scopes to affect each other's behavior.

  let mbCached = H.lookup (state ^. ssScopeName, source) (state ^. ssSourceCache)

      createRefs :: App StartingUp (IORef Text, Cache)
      createRefs = do
        (outputRef, cacheRef) <- liftIO $
          liftA2 (,) (newIORef "") (newIORef Nothing)
        modify $ ssSourceQueue <>~
          [(source, outputRef, cacheRef, state ^. ssScopeName)]
        pure (outputRef, cacheRef)

  (outputRef, cacheRef) <- maybe createRefs pure mbCached

  pure $ BarSource $ SourceHandle outputRef cacheRef escape

initialize (BarMarquee i p) =
  BarMarquee i <$> initialize p
initialize (BarSlider slider children) = do
  barSettings <- (^. ssBarSettings) <$> get

  -- Convert delay of a slider from microseconds to frames.
  let updateInterval = barSettings ^. bsUpdateInterval
      slider' = slider & sliderDelay %~ (\x -> x * 1000 `div` positive updateInterval)

  BarSlider slider' <$> mapM initialize children

initialize (BarAutomaton address rawSTT rawStateMap) = do
  state <- get

  let scope = state ^. ssScopeName

      mbCached = H.lookup (scope, address) (state ^. ssAutomataCache)

      newBarRef = do
        let initialState = ""

        -- Add current scope to the state transition table.
        let stt = STT
                . H.fromList
                . map (first (_scope .~ state ^. ssScopeName))
                . H.toList
                . unSTT
                $ rawSTT

        -- Create a reference to the current state
        stateRef :: IORef Text <- liftIO $ newIORef initialState

        -- Initialize all children
        stateMap :: H.HashMap Text (Bar Initialized) <- mapM initialize rawStateMap

        -- Create a reference to the current Bar (so that collectSources will not need to
        -- look up the correct Bar in stateMap).
        barRef :: IORef (Bar Initialized) <- liftIO $
          newIORef $ fromMaybe mempty (H.lookup initialState stateMap)

        let subscription = [ AutomatonSubscription address stt stateMap stateRef barRef ]

        -- Bind new subscription to the scope.
        modify $ ssSubscriptions %~ H.insertWith (++) scope subscription

        -- Cache this automaton
        let cacheEntry = (barRef, rawSTT, rawStateMap)

        modify $ ssAutomataCache %~ H.insert (scope, address) cacheEntry

        pure cacheEntry

  (barRef, cachedSTT, cachedStateMap) <- maybe newBarRef pure mbCached

  -- Eventually this should be moved to `Validation.hs`. We need a complete
  -- `Bar` tree available to perform this check, but `Validation.hs` only works
  -- with tokens at the moment of writing.
  when (cachedSTT /= rawSTT || cachedStateMap /= rawStateMap) do
    exit 1 $
      fromLines [ "Automata adresses must be unique per scope!"
                , "Found distinct automata definitions for address " <> address
                ]

  pure $ BarAutomaton address () barRef

initialize (BarScope child) = do
  counter <- getNonce
  oldScopeName <- (^. ssScopeName) <$> get
  modify $ ssScopeName <>~ ("-" <> showPack counter)
  child' <- initialize child
  modify $ ssScopeName .~ oldScopeName
  pure child'

initialize (BarProp (CA ca) child) = do

  identifier <- getNonce
  namedPipe  <- get <&> (^. ssNamedPipe)
  scope      <- get <&> (^. ssScopeName)

  let command =
        "echo click:" <> showPack identifier <>
        "@" <> scope <> " >> " <>
        T.pack namedPipe

  modify $ ssClickableAreas %~ H.insert identifier (ca ^. caCommand)

  BarProp (CA (ca & caCommand .~ command)) <$> initialize child

initialize (BarProp prop p) =
  BarProp prop <$> initialize p
initialize (BarDefine var) = do

  scope <- get <&> (^. ssScopeName)

  modify $
    ssVariableDefinitions %~
    ((scope, var ^. varName, var ^. varValue) :)

  pure mempty
initialize (BarPad width padding p) =
  BarPad width padding <$> initialize p
initialize (BarTrim width direction p) =
  BarTrim width direction <$> initialize p
initialize (Bars ps) =
  Bars <$> mapM initialize ps
initialize (BarShape (I image))
  | isImageContents image = do

      images          <- get <&> (^. ssImages)
      imagePathPrefix <- get <&> (^. ssImagePathPrefix)

      imageId <- case H.lookup image images of
                   Just imageId ->
                     pure imageId
                   Nothing -> do
                     imageId <- showPack <$> getNonce
                     modify $ ssImages %~ H.insert image imageId
                     pure imageId

      pure $ BarShape $ I $ T.pack imagePathPrefix <> imageId <> ".xbm"

initialize (BarShape shape) =
  pure $ BarShape shape
initialize (BarMarkup text) =
  pure $ BarMarkup text
initialize (BarText text) =
  pure $ BarText text

isImageContents :: Text -> Bool
isImageContents =
  T.isInfixOf "#define"

-- | Run source process either once or forever, depending on source settings.
mkThread
  :: [(String, String)]
  -> BarRuntime
  -> Source
  -> IORef Text
  -> Cache
  -> Text
  -> App StartingUp ()
mkThread _ _ Source { command = [] } outputRef cacheRef _scope = do
  let message = "dzen-dhall error: no command specified"
  liftIO $ do
    writeIORef cacheRef $ Just message
    writeIORef outputRef message
mkThread
  environment
  barRuntime
  Source { updateInterval
         , command = (binary : args)
         , input }
  outputRef
  cacheRef
  scope = do

  let emitter =
        barRuntime ^. brEmitterScript <> " " <> T.unpack scope
      getter =
        barRuntime ^. brGetterScript  <> " " <> T.unpack scope
      setter =
        barRuntime ^. brSetterScript  <> " " <> T.unpack scope

      sourceProcess =
        (proc binary args) { std_out = CreatePipe
                           , std_in  = CreatePipe
                           , std_err = CreatePipe
                           , env = Just $
                             [ ("EMIT", emitter)
                             , ("GET",  getter)
                             , ("SET",  setter)
                             ] <>
                             environment
                           }

  forkApp
    case updateInterval of

      -- If update interval is specified, loop forever.
      Just interval -> do
        timely interval $ liftIO do
          runSourceProcess sourceProcess outputRef cacheRef input

      -- If update interval is not specified, run the source once.
      Nothing ->
        liftIO $
          runSourceProcess sourceProcess outputRef cacheRef input


-- | Creates a process, subscribes to its stdout handle and updates the output ref.
runSourceProcess
  :: CreateProcess
  -> IORef Text
  -> Cache
  -> Text
  -> IO ()
runSourceProcess cp outputRef cacheRef input = do
  (mb_stdin_hdl, mb_stdout_hdl, mb_stderr_hdl, ph) <- createProcess cp

  case (mb_stdin_hdl, mb_stdout_hdl, mb_stderr_hdl) of
    (Just stdin, Just stdout, _) -> do
      hSetEncoding  stdin  System.IO.utf8
      hSetEncoding  stdout System.IO.utf8
      hSetBuffering stdin  LineBuffering
      hSetBuffering stdout LineBuffering

      T.hPutStrLn stdin input
      hClose stdin

      P.runEffect do
        P.for (P.fromHandle stdout) \line -> P.lift do

          -- Drop cache
          writeIORef cacheRef Nothing
          writeIORef outputRef (T.pack line)

      void $ waitForProcess ph

    _ -> do
      putStrLn "dzen-dhall error: Couldn't open IO handle(s)"


-- | Reads outputs of 'SourceHandle's and puts them into an AST.
collectSources
  :: Bar Initialized
  -> App Forked AST
collectSources (BarSource handle) = liftIO do
  let outputRef  = handle ^. shOutputRef
      cacheRef   = handle ^. shCacheRef
      escape     = handle ^. shEscape

  cache <- readIORef cacheRef
  case cache of
    Just escaped ->
      pure $ ASTText escaped
    Nothing -> do
      raw <- readIORef outputRef
      let escaped = escapeMarkup escape raw
      writeIORef cacheRef (Just escaped)
      pure $ ASTText escaped

collectSources (BarMarquee marquee p) = do

  ast          <- collectSources p
  frameCounter <- view brFrameCounter <$> App.get
  fontWidth    <- App.get <&> (^. brConfiguration . cfgBarSettings . bsFontWidth)
  pure $ Marquee.run fontWidth marquee ast frameCounter

collectSources (BarSlider slider ss) = do

  frameCounter <- view brFrameCounter <$> App.get
  asts         <- mapM collectSources ss
  pure $ Slider.run slider frameCounter asts

collectSources (BarAutomaton _ _ ref) = do

  bar          <- liftIO (readIORef ref)
  collectSources bar

collectSources (BarScope child) = do
  collectSources child

collectSources (BarPad width padding child) = do
  ASTPadding width padding <$> collectSources child

collectSources (BarTrim width direction child) = do
  ast <- collectSources child
  case direction of
    DRight ->
      pure $ fst $ split width ast
    DLeft -> do
      let actualWidth = astWidth ast
      pure $ snd $ split (abs $ actualWidth - width) ast

collectSources (BarShape shape) = do
  pure $ ASTShape shape

collectSources (BarProp prop child)
  = ASTProp prop <$> collectSources child
collectSources  (BarDefine _prop)
  = pure mempty
collectSources (Bars ps)
  = mconcat <$> mapM collectSources ps
collectSources (BarText text)
  = pure $ ASTText text
collectSources (BarMarkup text)
  = pure $ ASTText text


-- | Escape @^@ characters.
escapeMarkup
  :: Bool
  -> Text
  -> Text
escapeMarkup escape =
  (if escape
   then T.replace "^" "^^"
   else id)

allButtons :: [Button]
allButtons =
  [ MouseLeft
  , MouseMiddle
  , MouseRight
  , MouseScrollUp
  , MouseScrollDown
  , MouseScrollLeft
  , MouseScrollRight
  ]
