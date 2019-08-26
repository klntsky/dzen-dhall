{-# LANGUAGE TemplateHaskell #-}
-- | Everything needed to convert an 'AST' to 'Text'.
module DzenDhall.AST.Render where

import           DzenDhall.AST
import           DzenDhall.Config
import           DzenDhall.Data
import           DzenDhall.Extra

import           Control.Monad.Trans.Class
import           Control.Monad.Trans.State
import           Control.Monad.Trans.Writer
import           Data.Maybe
import           Control.Monad
import           Data.Text (Text)
import           Lens.Micro
import           Lens.Micro.TH
import qualified Data.Text

-- | Stacks are used to backtrack various dzen markup language tags.
--
-- Dzen itself does not perform backtracking, thus, for example, the letter @"c"@
-- in @^fg(red)a^fg(green)b^fg()c^fg()@ will not be colorized,
-- but 'render' definition for 'AST' mitigates this flaw.
--
-- For example,
--
-- @
-- runRender $
--   ASTProp (FG $ Color "red")
--     (ASTs (ASTs (ASTText "a")
--                 (ASTProp (FG $ Color "green")
--                   (ASTText "b")))
--           (ASTText "c"))
-- @
--
-- will be rendered as @^fg(red)a^fg(green)b^fg(red)c^fg()@
-- (so that @"c"@ will be red).
data RenderState
  = RenderState
  { _bgStack :: [Color]
  , _fgStack :: [Color]
  , _ibStack :: [IgnoreBackground]
  }

-- | A flag that indicates that background should be ignored (analogous to @^ib()@ dzen markup command).
data IgnoreBackground = IgnoreBackground

makeLenses ''RenderState

type Stack a = Lens' RenderState [a]

type Render = StateT RenderState (Writer Text)

runRender :: Renderable a => a -> Text
runRender a = snd $ runWriter (runStateT (render a) $ RenderState [] [] [])

class Renderable a where
  render :: a -> Render ()

instance Renderable IgnoreBackground where
  render IgnoreBackground = write "1"

instance Renderable Color where
  render = write . \case
    Color color -> color

instance Renderable Button where
  render = write . \case
    MouseLeft        -> "1"
    MouseMiddle      -> "2"
    MouseRight       -> "3"
    MouseScrollUp    -> "4"
    MouseScrollDown  -> "5"
    MouseScrollLeft  -> "6"
    MouseScrollRight -> "7"

instance Renderable Event where
  render (Event event) = write event

instance Renderable ClickableArea where
  render ca = do
    render $ ca ^. caButton
    write ","
    write $ ca ^. caCommand

instance Renderable AbsolutePosition where
  render position =
    write $ showPack (position ^. apX) <> ";" <> showPack (position ^. apY)

instance Renderable Shape where
  render = write . \case
    I path -> "^i("  <> path       <> ")"
    R w h  -> "^r("  <> showPack w <> "x" <> showPack h <> ")"
    RO w h -> "^ro(" <> showPack w <> "x" <> showPack h <> ")"
    C r    -> "^c("  <> showPack r <> ")"
    CO r   -> "^co(" <> showPack r <> ")"

instance Renderable AST where
  render EmptyAST =
    pure ()
  render (ASTText text) =
    write text
  render (ASTs a b) =
    (<>) <$> render a <*> render b
  render (ASTProp (FG color) ast) =
    usingStackWithTag fgStack "fg" color ast
  render (ASTProp (BG color) ast) =
    usingStackWithTag bgStack "bg" color ast
  render (ASTProp IB ast) =
    usingStackWithTag ibStack "ib" IgnoreBackground ast
  render (ASTProp (CA ca) ast) = do
    write "^ca("
    render ca
    write ")"
    render ast
    write "^ca()"
  render (ASTProp (PA position) ast) = do
    write "^pa("
    render position
    write ")"
    render ast
  render (ASTProp (P position) ast) = do
    write open
    render ast
    write close
    where
      (open, close) =
        case position of
          XY (x, y)  ->
            ( "^p(" <> showPack x    <> ";" <> showPack y    <> ")"
            , "^p(" <> showPack (-x) <> ";" <> showPack (-y) <> ")"
            )
          P_RESET_Y  -> ("^p()",                  "")
          P_LOCK_X   -> ("^p(_LOCK_X)",           "")
          P_UNLOCK_X -> ("^p(_UNLOCK_X)",         "")
          P_LEFT     -> ("^p(_LOCK_X)^p(_LEFT)",  "^p(_UNLOCK_X)")
          P_RIGHT    -> ("^p(_LOCK_X)^p(_RIGHT)", "^p(_UNLOCK_X)")
          P_TOP      -> ("^p(_TOP)",              "^p()")
          P_CENTER   -> ("^p(_CENTER)",           "^p()")
          P_BOTTOM   -> ("^p(_BOTTOM)",           "^p()")
  render (ASTShape shape) = render shape
  render (ASTPadding width padding ast) = do
    write $ mkPaddingText leftPadding
    render ast
    write $ mkPaddingText rightPadding
    where
      mkPaddingText n = Data.Text.justifyRight n ' ' ""
      (leftPadding, rightPadding) =
        paddingWidths padding $ width - astWidth ast


-- * Helper functions

write :: Text -> Render ()
write = lift . tell

-- | @^fg()@, @^bg()@ and @^ib()@ are rendered using the same algorithm.
usingStackWithTag :: Renderable a => Stack a -> Text -> a -> AST -> Render ()
usingStackWithTag stack tag value ast = do
    push stack value
    write $ "^" <> tag <> "("
    render value
    write ")"
    render ast
    void $ pop stack
    renew stack tag

pop :: Stack a -> Render (Maybe a)
pop stack = do
  st <- get
  put $ st & stack %~ (fromMaybe [] . safeTail)
  pure $ safeHead $ st ^. stack

push :: Stack a -> a -> Render ()
push stack value = modify (& stack %~ (value :))

renew :: Renderable a => Stack a -> Text -> Render ()
renew stack tag = do
  mbOld <- pop stack
  write $ "^" <> tag <> "("
  case mbOld of
    Just old -> do
      render old
      push stack old
    Nothing -> pure ()
  write ")"
