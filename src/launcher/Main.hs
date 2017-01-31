{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

import           Control.Concurrent.Async hiding (wait)
import           Options.Applicative      (Parser, ParserInfo, auto, execParser, fullDesc,
                                           help, helper, info, long, metavar, option,
                                           progDesc, short, strOption)
import qualified System.IO                as IO
import           System.Process           (ProcessHandle)
import qualified System.Process           as Process
import           System.Timeout           (timeout)
import           Turtle                   hiding (option, toText)
import           Universum                hiding (FilePath)

import           Control.Exception        (handle, mask_, throwIO)
import           Foreign.C.Error          (Errno (..), ePIPE)
import           GHC.IO.Exception         (IOErrorType (..), IOException (..))

data LauncherOptions = LO
    { loNodePath       :: FilePath
    , loNodeArgs       :: [Text]
    , loNodeLogPath    :: Maybe FilePath
    , loWalletPath     :: Maybe FilePath
    , loWalletArgs     :: [Text]
    , loUpdaterPath    :: FilePath
    , loUpdaterArgs    :: [Text]
    , loUpdateArchive  :: Maybe FilePath
    , loNodeTimeoutSec :: Int
    }

optsParser :: Parser LauncherOptions
optsParser = LO
    <$> (fromString <$> strOption (
             long "node" <>
             metavar "PATH" <>
             help "Path to the node executable"))
    <*> (many $ toText <$> strOption (
             short 'n' <>
             metavar "ARG" <>
             help "An argument to be passed to the node"))
    <*> (optional $ fromString <$> strOption (
             long "node-log" <>
             metavar "PATH" <>
             help "Path to the log where node's output will be dumped"))
    <*> (optional $ fromString <$> strOption (
             long "wallet" <>
             metavar "PATH" <>
             help "Path to the wallet executable"))
    <*> (many $ toText <$> strOption (
             short 'w' <>
             metavar "ARG" <>
             help "An argument to be passed to the wallet"))
    <*> (fromString <$> strOption (
             long "updater" <>
             metavar "PATH" <>
             help "Path to the updater executable"))
    <*> (many $ toText <$> strOption (
             short 'u' <>
             metavar "ARG" <>
             help "An argument to be passed to the updater"))
    <*> (optional $ fromString <$> strOption (
             long "update-archive" <>
             metavar "PATH" <>
             help "Path to the update archive \
                  \(will be passed to the updater)"))
    <*> (option auto (
             long "node-timeout" <>
             metavar "SEC" <>
             help "How much to wait for the node to exit \
                  \before killing it"))

optsInfo :: ParserInfo LauncherOptions
optsInfo = info (helper <*> optsParser) $
    fullDesc `mappend` progDesc "Tool to launch Cardano SL"

main :: IO ()
main = do
    LO {..} <- execParser optsInfo
    sh $ case loWalletPath of
             Nothing ->
                 serverScenario
                     (loNodePath, loNodeArgs, loNodeLogPath)
                     (loUpdaterPath, loUpdaterArgs, loUpdateArchive)
             Just wpath ->
                 clientScenario
                     (loNodePath, loNodeArgs, loNodeLogPath)
                     (wpath, loWalletArgs)
                     (loUpdaterPath, loUpdaterArgs, loUpdateArchive)
                     loNodeTimeoutSec

-- | If we are on server, we want the following algorithm:
--
-- * Update (if we are already up-to-date, nothing will happen).
-- * Launch the node.
-- * If it exits with code 20, then update and restart, else quit.
serverScenario
    :: (FilePath, [Text], Maybe FilePath)  -- ^ Node, its args, node log
    -> (FilePath, [Text], Maybe FilePath)  -- ^ Updater, args, the update .tar
    -> Shell ()
serverScenario node updater = do
    runUpdater updater
    -- TODO: somehow signal updater failure if it fails? would be nice to
    -- write it into the log, at least
    (_, nodeAsync) <- spawnNode node
    exitCode <- wait nodeAsync
    printf ("The node has exited with "%s%"\n") (show exitCode)
    case exitCode of
        ExitFailure 20 -> serverScenario node updater
        _              -> return ()

-- | If we are on desktop, we want the following algorithm:
--
-- * Update (if we are already up-to-date, nothing will happen).
-- * Launch the node and the wallet.
-- * If the wallet exits with code 20, then update and restart, else quit.
--
clientScenario
    :: (FilePath, [Text], Maybe FilePath)  -- ^ Node, its args, node log
    -> (FilePath, [Text])                  -- ^ Wallet, args
    -> (FilePath, [Text], Maybe FilePath)  -- ^ Updater, args, the update .tar
    -> Int                                 -- ^ Node timeout, in seconds
    -> Shell ()
clientScenario node wallet updater nodeTimeout = do
    runUpdater updater
    -- I don't know why but a process started with turtle just can't be
    -- killed, so let's use 'terminateProcess' and modified 'system'
    (nodeHandle, nodeAsync) <- spawnNode node
    walletAsync <- fork (runWallet wallet)
    (someAsync, exitCode) <- liftIO $ waitAny [nodeAsync, walletAsync]
    if | someAsync == nodeAsync -> do
             printf ("The node has exited with "%s%"\n") (show exitCode)
             echo "Waiting for the wallet to die"
             void $ wait walletAsync
       | exitCode == ExitFailure 20 -> do
             echo "The wallet has exited with code 20"
             printf ("Killing the node in "%d%" seconds\n") nodeTimeout
             sleep (fromIntegral nodeTimeout)
             echo "Killing the node now"
             liftIO $ do
                 Process.terminateProcess nodeHandle
                 cancel nodeAsync
             clientScenario node wallet updater nodeTimeout
       | otherwise -> do
             printf ("The wallet has exited with "%s%"\n") (show exitCode)
             echo "Killing the node"
             liftIO $ do
                 Process.terminateProcess nodeHandle
                 cancel nodeAsync

-- | We run the updater and delete the update file if the update was
-- successful.
runUpdater :: (FilePath, [Text], Maybe FilePath) -> Shell ()
runUpdater (path, args, updateArchive) = do
    exists <- testfile path
    if not exists then
        printf ("The updater at "%fp%" doesn't exist, skipping the update\n")
               path
    else do
        echo "Running the updater"
        let args' = args ++ maybe [] (one . toText) updateArchive
        exitCode <- proc (toText path) args' mempty
        printf ("The updater has exited with "%s%"\n") (show exitCode)
        when (exitCode == ExitSuccess) $ do
            -- this will throw an exception if the file doesn't exist but
            -- hopefully if the updater has succeeded it *does* exist
            whenJust updateArchive rm

----------------------------------------------------------------------------
-- Running stuff
----------------------------------------------------------------------------

spawnNode
    :: (FilePath, [Text], Maybe FilePath)
    -> Shell (ProcessHandle, Async ExitCode)
spawnNode (path, args, logPath) = do
    echo "Starting the node"
    logOut <- case logPath of
        Nothing -> return Process.Inherit
        Just lp -> do logHandle <- openFile (toString lp) AppendMode
                      liftIO $ IO.hSetBuffering logHandle IO.LineBuffering
                      return (Process.UseHandle logHandle)
    let cr = (Process.proc (toString path) (map toString args))
                 { Process.std_in  = Process.CreatePipe
                 , Process.std_out = logOut
                 , Process.std_err = logOut
                 }
    phvar <- liftIO newEmptyMVar
    asc <- fork (system' phvar cr mempty)
    mbPh <- liftIO $ timeout 5000000 (takeMVar phvar)
    case mbPh of
        Nothing -> panic "couldn't run the node (it didn't start after 5s)"
        Just ph -> return (ph, asc)

runWallet :: (FilePath, [Text]) -> IO ExitCode
runWallet (path, args) = do
    echo "Starting the wallet"
    proc (toText path) args mempty

----------------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------------

instance ToString FilePath where
    toString = toString . format fp

instance ToText FilePath where
    toText = format fp

----------------------------------------------------------------------------
-- Turtle internals, modified to give access to process handles
----------------------------------------------------------------------------

{-
shell'
    :: MonadIO io
    => MVar ProcessHandle
    -- ^ Where to put process handle
    -> Text
    -- ^ Command line
    -> Shell Line
    -- ^ Lines of standard input
    -> io ExitCode
    -- ^ Exit code
shell' phvar cmdLine =
    system' phvar
        ( (Process.shell (toString cmdLine))
            { Process.std_in  = Process.CreatePipe
            , Process.std_out = Process.Inherit
            , Process.std_err = Process.Inherit
            } )
-}

system'
    :: MonadIO io
    => MVar ProcessHandle
    -- ^ Where to put process handle
    -> Process.CreateProcess
    -- ^ Command
    -> Shell Line
    -- ^ Lines of standard input
    -> io ExitCode
    -- ^ Exit code
system' phvar p sl = liftIO (do
    let open = do
            (m, _, _, ph) <- Process.createProcess p
            putMVar phvar ph
            case m of
                Just hIn -> IO.hSetBuffering hIn IO.LineBuffering
                _        -> return ()
            return (m, ph)

    -- Prevent double close
    mvar <- newMVar False
    let close hdl = do
            modifyMVar_ mvar (\finalized -> do
                unless finalized (ignoreSIGPIPE (IO.hClose hdl))
                return True )
    let close' (Just hIn, ph) = do
            close hIn
            Process.terminateProcess ph
        close' (Nothing , ph) = do
            Process.terminateProcess ph

    let handle_ (Just hIn, ph) = do
            let feedIn :: (forall a. IO a -> IO a) -> IO ()
                feedIn restore =
                    restore (ignoreSIGPIPE (outhandle hIn sl)) `finally` close hIn
            mask_ (withAsyncWithUnmask feedIn (\a -> Process.waitForProcess ph <* halt a) )
        handle_ (Nothing , ph) = do
            Process.waitForProcess ph

    bracket open close' handle_ )

halt :: Async a -> IO ()
halt a = do
    m <- poll a
    case m of
        Nothing          -> cancel a
        Just (Left  msg) -> throwIO msg
        Just (Right _)   -> return ()

ignoreSIGPIPE :: IO () -> IO ()
ignoreSIGPIPE = handle (\ex -> case ex of
    IOError
        { ioe_type = ResourceVanished
        , ioe_errno = Just ioe }
        | Errno ioe == ePIPE -> return ()
    _ -> throwIO ex )