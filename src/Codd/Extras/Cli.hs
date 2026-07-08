module Codd.Extras.Cli
  ( CheckMode (..),
    MigrationCliConfig (..),
    migrationCliMain,
    parseCheckModeEnv,
    printMigrationStatus,
    renderLedgerSchema,
  )
where

import Codd (ApplyResult (..), CoddSettings)
import Codd.Environment (getCoddSettings)
import Codd.Extras.Ledger (LedgerSchema (..), MigrationStatus (..), VerifyOutcome (..))
import Codd.Extras.LockFile (writeMigrationLock)
import Data.Char (isSpace, toLower)
import Data.Foldable (traverse_)
import Data.Maybe (fromMaybe)
import Data.Time (DiffTime, UTCTime)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

data CheckMode
  = Checked
  | NoCheck
  deriving stock (Eq, Show)

data MigrationCliConfig = MigrationCliConfig
  { programName :: !String,
    migrationsDirEnv :: !String,
    defaultMigrationsDir :: !FilePath,
    newMigrationFile :: !(FilePath -> String -> IO FilePath),
    runUp :: !(CheckMode -> CoddSettings -> DiffTime -> IO ApplyResult),
    verifySchema :: !(CoddSettings -> DiffTime -> IO VerifyOutcome),
    migrationStatus :: !(CoddSettings -> DiffTime -> IO MigrationStatus),
    connectTimeout :: !DiffTime,
    noCheckEnv :: !(Maybe String),
    embedRefreshHint :: !String
  }

migrationCliMain :: MigrationCliConfig -> IO ()
migrationCliMain config = do
  args <- getArgs
  case args of
    [] -> migrate config
    ["up"] -> migrate config
    ["verify"] -> verify config
    ["status"] -> status config
    ("new" : rest) -> generate config (unwords rest)
    ("lock" : _) -> writeLock config
    other -> usage config other

migrate :: MigrationCliConfig -> IO ()
migrate config = do
  settings <- getCoddSettings
  checkMode <- resolveCheckMode config
  result <- runUp config checkMode settings (connectTimeout config)
  case result of
    SchemasDiffer _ -> do
      hPutStrLn stderr "schema drift detected; see the codd diff above"
      exitWith (ExitFailure 1)
    SchemasMatch _ -> pure ()
    SchemasNotVerified -> pure ()

generate :: MigrationCliConfig -> String -> IO ()
generate config description
  | all isSpace description =
      ioError (userError ("usage: " <> programName config <> " new <description>"))
  | otherwise = do
      dir <- migrationsDir config
      path <- newMigrationFile config dir description
      putStrLn ("Created " <> path)
      putStrLn (embedRefreshHint config)

writeLock :: MigrationCliConfig -> IO ()
writeLock config = do
  dir <- migrationsDir config
  count <- writeMigrationLock dir "migrations.lock"
  putStrLn ("Wrote migrations.lock (" <> show count <> " migrations)")

status :: MigrationCliConfig -> IO ()
status config = do
  settings <- getCoddSettings
  migrationStatus config settings (connectTimeout config) >>= printMigrationStatus

verify :: MigrationCliConfig -> IO ()
verify config = do
  settings <- getCoddSettings
  outcome <- verifySchema config settings (connectTimeout config)
  case outcome of
    VerifySucceeded -> putStrLn "Schema matches expected snapshot."
    VerifyFailed -> exitWith (ExitFailure 1)
    VerifyPending pending -> do
      hPutStrLn stderr "Cannot verify while migrations are pending:"
      traverse_ (hPutStrLn stderr . ("  " <>)) pending
      exitWith (ExitFailure 2)

printMigrationStatus :: MigrationStatus -> IO ()
printMigrationStatus MigrationStatus {statusLedgerSchema, statusApplied, statusPending} = do
  putStrLn ("Ledger: " <> maybe "not found" renderLedgerSchema statusLedgerSchema)
  putStrLn ("Applied (" <> show (length statusApplied) <> "):")
  traverse_ printApplied statusApplied
  putStrLn ("Pending (" <> show (length statusPending) <> "):")
  traverse_ (putStrLn . ("  " <>)) statusPending
  putStrLn ("applied " <> show (length statusApplied) <> ", pending " <> show (length statusPending))

renderLedgerSchema :: LedgerSchema -> String
renderLedgerSchema CoddLedger = "codd.sql_migrations"
renderLedgerSchema CoddSchemaLedger = "codd_schema.sql_migrations"

printApplied :: (FilePath, UTCTime) -> IO ()
printApplied (name, timestamp) =
  putStrLn ("  " <> name <> "   " <> show timestamp)

resolveCheckMode :: MigrationCliConfig -> IO CheckMode
resolveCheckMode config =
  case noCheckEnv config of
    Nothing -> pure Checked
    Just envName -> parseCheckModeEnv envName =<< lookupEnv envName

parseCheckModeEnv :: String -> Maybe String -> IO CheckMode
parseCheckModeEnv _ Nothing = pure Checked
parseCheckModeEnv envName (Just raw)
  | lowered `elem` ["1", "true", "yes"] = pure NoCheck
  | null raw = pure Checked
  | otherwise = do
      hPutStrLn stderr ("Ignoring " <> envName <> "; accepted values are 1, true, yes")
      pure Checked
  where
    lowered = map toLower raw

migrationsDir :: MigrationCliConfig -> IO FilePath
migrationsDir config =
  fromMaybe (defaultMigrationsDir config) <$> lookupEnv (migrationsDirEnv config)

usage :: MigrationCliConfig -> [String] -> IO ()
usage config args = do
  hPutStrLn stderr ("unknown " <> programName config <> " arguments: " <> unwords args)
  hPutStrLn stderr ("usage: " <> programName config <> " [up | verify | status | new <description> | lock]")
  exitWith (ExitFailure 2)
