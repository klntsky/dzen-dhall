module DzenDhall.App.Run where

import           DzenDhall.App as App
import           DzenDhall.App.StartingUp
import           DzenDhall.App.Forked
import           DzenDhall.Config
import           DzenDhall.Data
import           DzenDhall.Event
import           DzenDhall.Extra
import           DzenDhall.Runtime.Data
import qualified DzenDhall.Validation as Validation
import qualified DzenDhall.Parser as Parser

import           Control.Monad
import           Lens.Micro
import           Lens.Micro.Extras
import           System.Exit
import           Control.Concurrent (threadDelay)


-- | Parses 'Bar's. For each 'Configuration' spawns its own dzen binary,
-- source threads and automata handlers.
useConfigurations :: App Common ()
useConfigurations = do
  checkDzen2Executable

  runtime <- App.getRuntime

  forM_ (view rtConfigurations runtime) \cfg -> do

    (errors, barTokens) <- liftIO $
      Validation.run $ cfg ^. cfgBarTokens

    unless (null errors) $
      App.exit 3 $ Validation.report errors

    withEither
      (Parser.runBarParser barTokens)
      (invalidTokens barTokens) $
      \(bar :: Bar Marshalled) -> do

        (bar', subscriptions, barRuntime, clickableAreas) <-
          liftStartingUp (startUp cfg bar) (cfg ^. cfgBarSettings)

        runAppForked barRuntime (launchEventListener subscriptions clickableAreas)

        runAppForked barRuntime (updateForever bar')

        -- This delay is required to preserve the order of multiple dzen2 instances.
        -- We want them to overlap in exactly the same order as defined in `config.dhall`.
        -- 50ms is nearly unnoticeable for humans, but just enough for dzen2 to connect to
        -- X and initialize its window.
        liftIO $ threadDelay 50000


checkDzen2Executable :: App stage ()
checkDzen2Executable = do
  runtime <- getRuntime
  liftIO $
    checkExecutables [runtime ^. rtDzenBinary] >>= mapM_
    (\executable -> do
        putStrLn $
          "Executable not in PATH: " <> executable <>
          ". See --dzen-binary argument."
        exitWith $ ExitFailure 1)


invalidTokens :: Show a => [Token] -> a -> App Common ()
invalidTokens barTokens err = do
  App.exit 3 $ fromLines
    [ "Internal error when parsing configuration, debug info: " <> showPack barTokens
    , "Error: " <> showPack err
    , "Please report as bug."
    ]
