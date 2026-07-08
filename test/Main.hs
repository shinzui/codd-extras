module Main (main) where

import Codd (ApplyResult (SchemasNotVerified))
import Codd.Extras.Apply (applyEmbeddedMigrationsNoCheck)
import Codd.Extras.Guards
  ( LintConfig (..),
    checksumViolations,
    duplicateTimestampViolations,
    lintViolations,
    parseChecksumManifest,
    renderChecksumManifest,
    sentinelViolations,
  )
import Codd.Extras.Ledger (MigrationStatus (..), migrationStatus)
import Codd.Extras.New qualified as New
import Codd.Extras.Settings (noCheckCoddSettings)
import Codd.Extras.Settings qualified as Codd.Extras.Settings
import Codd.Extras.TestSupport (withMigratedDatabase)
import Codd.Types (libpqConnString)
import Codd.Types qualified
import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple qualified as DB
import System.Directory (doesFileExist)
import System.FilePath (takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main =
  hspec $ do
    describe "migration integrity guards" $ do
      it "detects hand-assigned and duplicate timestamp prefixes" $ do
        sentinelViolations ["2026-01-01-00-00-00-alpha.sql"] `shouldSatisfy` (not . null)
        duplicateTimestampViolations ["2026-01-01-12-00-01-alpha.sql", "2026-01-01-12-00-01-beta.sql"] `shouldSatisfy` (not . null)

      it "lints schema qualification and codd no-txn requirements" $ do
        let sources =
              [ ("2026-01-01-12-00-01-good.sql", "CREATE TABLE app.widgets (widget_id int PRIMARY KEY);"),
                ("2026-01-01-12-00-02-unqualified.sql", "CREATE TABLE widgets (widget_id int PRIMARY KEY);"),
                ("2026-01-01-12-00-03-concurrent.sql", "CREATE INDEX CONCURRENTLY app_widgets_idx ON app.widgets (widget_id);")
              ]
        lintViolations LintConfig {requiredQualifier = "app.", exemptFiles = []} sources
          `shouldBe` [ "migration DDL target is not qualified with app. in 2026-01-01-12-00-02-unqualified.sql: CREATE TABLE widgets (widget_id int PRIMARY KEY)",
                       "migration uses CONCURRENTLY without -- codd: no-txn: 2026-01-01-12-00-03-concurrent.sql"
                     ]

      it "renders and checks migration lock manifests" $ do
        let sources = [("2026-01-01-12-00-01-alpha.sql", "SELECT 1;")]
            manifestText = renderChecksumManifest sources
        parseChecksumManifest manifestText `shouldBe` Right [("2026-01-01-12-00-01-alpha.sql", "17db4fd369edb9244b9f91d9aeed145c3d04ad8ba6e95d06247f07a63527d11a")]
        checksumViolations [("2026-01-01-12-00-01-alpha.sql", "bad")] sources
          `shouldBe` ["migrations.lock checksum mismatch for 2026-01-01-12-00-01-alpha.sql"]

    describe "migration scaffolding" $ do
      it "builds codd-compatible timestamped file names with optional prefixes" $ do
        let sampled = UTCTime (fromGregorian 2026 1 1) 43201.6
        New.migrationFileName prefixedMigrationConfig sampled "Add widget index"
          `shouldBe` "2026-01-01-12-00-02-app-add-widget-index.sql"
        New.migrationSlug (Just "app") "app-add widget index" `shouldBe` "app-add-widget-index"
        New.migrationSlug Nothing "Add widget index" `shouldBe` "add-widget-index"

      it "writes a migration skeleton" $
        withSystemTempDirectory "codd-extras-new" $ \dir -> do
          path <- New.newMigrationFile prefixedMigrationConfig dir "add widget index"
          path `shouldSatisfy` (("app-add-widget-index.sql" ==) . dropTimestamp)
          doesFileExist path `shouldReturn` True
          readFile path `shouldReturn` "-- add widget index\n"

    it "applies multiple embedded migration groups once into one shared ledger" $
      withMigratedDatabase applyTestMigrations $ \connStr -> do
        assertRegclass connStr "alpha.widgets"
        assertRegclass connStr "beta.widgets"
        ledger <- ledgerNames connStr
        ledger `shouldBe` map fst (alphaMigrations <> betaMigrations)

        beforeCount <- ledgerRowCount connStr
        applyTestMigrations connStr
        afterCount <- ledgerRowCount connStr
        afterCount `shouldBe` beforeCount

        status <- migrationStatus (map fst (alphaMigrations <> betaMigrations)) (migsConnStringFor connStr) (secondsToDiffTime 5)
        map fst (statusApplied status) `shouldBe` map fst (alphaMigrations <> betaMigrations)
        statusPending status `shouldBe` []

    it "reports partially-applied no-txn ledger rows as pending" $
      withMigratedDatabase applyTestMigrations $ \connStr -> do
        let partialName = "2026-01-01-00-00-03-partial.sql"
        insertPartialLedgerRow connStr partialName
        status <- migrationStatus (map fst (alphaMigrations <> betaMigrations) <> [partialName]) (migsConnStringFor connStr) (secondsToDiffTime 5)
        map fst (statusApplied status) `shouldBe` map fst (alphaMigrations <> betaMigrations)
        statusPending status `shouldBe` [partialName]

applyTestMigrations :: Text -> IO ()
applyTestMigrations connStr = do
  result <-
    applyEmbeddedMigrationsNoCheck
      (noCheckCoddSettings ["alpha", "beta"] connStr)
      (secondsToDiffTime 5)
      [ ("Alpha", alphaMigrations),
        ("Beta", betaMigrations)
      ]
  result `shouldBeSchemasNotVerified` "test migration run"

alphaMigrations :: [(FilePath, ByteString)]
alphaMigrations =
  [ ( "2026-01-01-00-00-01-alpha.sql",
      "CREATE SCHEMA IF NOT EXISTS alpha;\n\
      \CREATE TABLE alpha.widgets (widget_id int PRIMARY KEY);\n"
    )
  ]

betaMigrations :: [(FilePath, ByteString)]
betaMigrations =
  [ ( "2026-01-01-00-00-02-beta.sql",
      "CREATE SCHEMA IF NOT EXISTS beta;\n\
      \CREATE TABLE beta.widgets (widget_id int PRIMARY KEY);\n"
    )
  ]

migsConnStringFor :: Text -> Codd.Types.ConnectionString
migsConnStringFor = Codd.Extras.Settings.parseConnString

shouldBeSchemasNotVerified :: ApplyResult -> String -> Expectation
shouldBeSchemasNotVerified SchemasNotVerified _ = pure ()
shouldBeSchemasNotVerified _ label = expectationFailure (label <> " unexpectedly verified schemas")

withConn :: Text -> (DB.Connection -> IO a) -> IO a
withConn connStr =
  bracket (DB.connectPostgreSQL (libpqConnString (migsConnStringFor connStr))) DB.close

assertRegclass :: Text -> Text -> Expectation
assertRegclass connStr relationName =
  withConn connStr $ \conn -> do
    [DB.Only exists] <- DB.query conn "SELECT to_regclass(?) IS NOT NULL" (DB.Only relationName)
    exists `shouldBe` True

ledgerNames :: Text -> IO [FilePath]
ledgerNames connStr =
  withConn connStr $ \conn ->
    fmap DB.fromOnly <$> DB.query_ conn "SELECT name FROM codd.sql_migrations ORDER BY name"

ledgerRowCount :: Text -> IO Int
ledgerRowCount connStr =
  withConn connStr $ \conn -> do
    [DB.Only count] <- DB.query_ conn "SELECT count(*)::int FROM codd.sql_migrations"
    pure count

insertPartialLedgerRow :: Text -> FilePath -> IO ()
insertPartialLedgerRow connStr name =
  withConn connStr $ \conn -> do
    _ <-
      DB.execute
        conn
        "INSERT INTO codd.sql_migrations \
        \(migration_timestamp, name, application_duration, num_applied_statements, applied_at, no_txn_failed_at) \
        \VALUES ('2026-01-01 00:00:03+00', ?, '1 second', 1, NULL, now())"
        (DB.Only name)
    pure ()

prefixedMigrationConfig :: New.MigrationFileConfig
prefixedMigrationConfig =
  New.MigrationFileConfig
    { New.migrationSlugPrefix = Just "app",
      New.migrationTemplate = \description -> "-- " <> description <> "\n"
    }

dropTimestamp :: FilePath -> FilePath
dropTimestamp = drop 20 . takeFileName
