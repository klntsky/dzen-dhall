{-# LANGUAGE TemplateHaskell #-}
module DzenDhall.Runtime where

import           DzenDhall.Arguments
import           DzenDhall.Event
import           DzenDhall.Data
import           DzenDhall.Config hiding (Hook)
import           Paths_dzen_dhall

import           Control.Monad
import           Data.Maybe
import           Data.IORef
import           Dhall hiding (maybe)
import           Lens.Micro
import           Lens.Micro.TH
import           System.Directory
import           System.Exit (ExitCode(..), exitWith)
import           System.FilePath ((</>))
import           System.Posix.Files
import           System.IO
import qualified Data.HashMap.Strict as H

apiVersion :: Int
apiVersion = 1

data Runtime = Runtime
  { _rtConfigDir :: String
  , _rtConfigurations :: [Configuration]
  , _rtDzenBinary :: String
  , _rtAPIVersion :: Int
  , _rtArguments :: Arguments
  }
  deriving (Eq, Show)

makeLenses ''Runtime

data StartupState
  = StartupState
  { _ssAutomataHandles :: AutomataHandles
  , _ssScopeName :: Text
  , _ssBarSettings :: BarSettings
  , _ssCounter :: Int
  -- ^ Counter that is incremented each time it is requested (used as a source
  -- of unique identifiers). See also: 'DzenDhall.App.getCounter'
  , _ssSourceCache :: H.HashMap (Text, Source) (IORef Text, Cache)
  , _ssAutomataCache :: H.HashMap (Text, Text) (IORef (Bar Initialized))
  }

makeLenses ''StartupState

data BarRuntime = BarRuntime
  { _brConfiguration :: Configuration
  , _brFrameCounter :: Int
  , _brNamedPipe :: String
  -- ^ Named pipe to use as a communication channel for listening to mouse events
  , _brHandle :: Handle
  -- ^ A handle to write to. The value is either stdin of a @dzen2@ process or
  -- 'System.IO.stdout', if @--stdout@ flag is passed.
  }
  deriving (Eq, Show)

makeLenses ''BarRuntime

-- Read runtime from configuration file, if possible.
readRuntime :: Arguments -> IO Runtime
readRuntime args = do
  let dzenBinary = fromMaybe "dzen2" (args ^. mbDzenBinary)

  configDir <- maybe (getXdgDirectory XdgConfig "dzen-dhall") pure (args ^. mbConfigDir)
  exists <- doesDirectoryExist configDir

  unless exists $ do
    putStrLn "Configuration directory does not exist, you should create it first by running `dzen-dhall init`."
    exitWith $ ExitFailure 2

  let configFile = configDir </> "config.dhall"

  putStrLn $ "Reading configuration from " <> configFile

  configurations :: [Configuration] <- do
    detailed $ inputFile (list configurationType) configFile

  pure $ Runtime
    configDir
    configurations
    dzenBinary
    apiVersion
    args

-- | Create config directory and set file permissions.
initCommand :: Arguments -> IO ()
initCommand args = do
  configDir <- maybe (getXdgDirectory XdgConfig "dzen-dhall") pure (args ^. mbConfigDir)

  let pluginsDir = configDir </> "plugins"
      srcDir     = configDir </> "src"
      libDir     = configDir </> "lib"

  exists <- doesDirectoryExist configDir

  when exists $ do
    putStrLn "Configuration directory already exists."
    exitWith (ExitFailure 1)

  dataDir <- getDataDir

  createDirectoryIfMissing True configDir
  createDirectoryIfMissing True pluginsDir

  let mode400 = ownerReadMode
      mode600 = mode400 `unionFileModes` ownerWriteMode
      mode700 = mode600 `unionFileModes` ownerExecuteMode

  copyDir
    -- for files
    (`setFileMode` mode400)
    -- for directories
    (`setFileMode` mode700)
    (dataDir </> "dhall")
    configDir

  let configFile = configDir </> "config.dhall"

  setFileMode configDir  mode700
  setFileMode pluginsDir mode700
  setFileMode configFile mode600
  setFileMode srcDir     mode700
  setFileMode libDir     mode700

  putStrLn $ "Success! You can now view your configuration at " <> configFile
  putStrLn $ "Run dzen-dhall again to see it in action."

type Hook = FilePath -> IO ()

copyDir :: Hook -> Hook -> FilePath -> FilePath -> IO ()
copyDir fileCreationHook dirCreationHook = go
  where
    go src dst = do
      content <- listDirectory src
      forM_ content $ \name -> do
        let srcPath = src </> name
        let dstPath = dst </> name

        isDir <- doesDirectoryExist srcPath
        if isDir
          then do
          createDirectoryIfMissing True dstPath
          dirCreationHook dstPath
          go srcPath dstPath
          else do
          copyFile srcPath dstPath
          fileCreationHook dstPath
