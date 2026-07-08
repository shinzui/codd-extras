module Codd.Extras.MigrationSet
  ( ExpectedSchema (..),
    MigrationSet (..),
    applyMigrationSet,
    applyMigrationSetNoCheck,
    applyMigrationSets,
    applyMigrationSetsNoCheck,
    migrationGroup,
    migrationGroups,
    migrationNames,
    migrationNamesForSets,
    migrationStatusForNames,
    migrationStatusForSet,
    migrationStatusForSets,
    missingMigrationsForNames,
    missingMigrationsForSet,
    missingMigrationsForSets,
    parseMigrationSet,
    parseMigrationSets,
    verifyExpectedSchema,
  )
where

import Codd (ApplyResult, CoddSettings, VerifySchemas)
import Codd.Extras.Apply qualified as Apply
import Codd.Extras.Embedded qualified as Embedded
import Codd.Extras.Ledger (MigrationStatus, VerifyOutcome)
import Codd.Extras.Ledger qualified as Ledger
import Codd.Extras.Verify qualified as Verify
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Codd.Types (ConnectionString)
import Data.ByteString (ByteString)
import Data.List (sort)
import Data.Time (DiffTime)

data MigrationSet = MigrationSet
  { label :: !String,
    files :: ![(FilePath, ByteString)]
  }
  deriving stock (Eq, Show)

data ExpectedSchema = ExpectedSchema
  { label :: !String,
    files :: ![(FilePath, ByteString)]
  }
  deriving stock (Eq, Show)

migrationNames :: MigrationSet -> [FilePath]
migrationNames MigrationSet {files} =
  Embedded.embeddedMigrationNames files

migrationNamesForSets :: [MigrationSet] -> [FilePath]
migrationNamesForSets =
  sort . concatMap migrationNames

migrationGroup :: MigrationSet -> (String, [(FilePath, ByteString)])
migrationGroup MigrationSet {label, files} =
  (label, files)

migrationGroups :: [MigrationSet] -> [(String, [(FilePath, ByteString)])]
migrationGroups =
  map migrationGroup

parseMigrationSet ::
  (MonadFail m, EnvVars m) =>
  MigrationSet ->
  m [AddedSqlMigration m]
parseMigrationSet MigrationSet {label, files} =
  Embedded.parseEmbeddedMigrations label files

parseMigrationSets ::
  (MonadFail m, EnvVars m) =>
  [MigrationSet] ->
  m [AddedSqlMigration m]
parseMigrationSets sets =
  concat <$> traverse parseMigrationSet sets

applyMigrationSet ::
  CoddSettings ->
  DiffTime ->
  VerifySchemas ->
  MigrationSet ->
  IO ApplyResult
applyMigrationSet settings connectTimeout verifySchemas set =
  applyMigrationSets settings connectTimeout verifySchemas [set]

applyMigrationSets ::
  CoddSettings ->
  DiffTime ->
  VerifySchemas ->
  [MigrationSet] ->
  IO ApplyResult
applyMigrationSets settings connectTimeout verifySchemas sets =
  Apply.applyEmbeddedMigrations settings connectTimeout verifySchemas (migrationGroups sets)

applyMigrationSetNoCheck ::
  CoddSettings ->
  DiffTime ->
  MigrationSet ->
  IO ApplyResult
applyMigrationSetNoCheck settings connectTimeout set =
  applyMigrationSetsNoCheck settings connectTimeout [set]

applyMigrationSetsNoCheck ::
  CoddSettings ->
  DiffTime ->
  [MigrationSet] ->
  IO ApplyResult
applyMigrationSetsNoCheck settings connectTimeout sets =
  Apply.applyEmbeddedMigrationsNoCheck settings connectTimeout (migrationGroups sets)

verifyExpectedSchema ::
  [FilePath] ->
  ExpectedSchema ->
  CoddSettings ->
  DiffTime ->
  IO VerifyOutcome
verifyExpectedSchema expectedNames ExpectedSchema {label, files} =
  Verify.verifySchemaWith expectedNames files label

missingMigrationsForNames :: [FilePath] -> ConnectionString -> DiffTime -> IO [FilePath]
missingMigrationsForNames =
  Ledger.missingMigrations

missingMigrationsForSet :: MigrationSet -> ConnectionString -> DiffTime -> IO [FilePath]
missingMigrationsForSet set =
  missingMigrationsForNames (migrationNames set)

missingMigrationsForSets :: [MigrationSet] -> ConnectionString -> DiffTime -> IO [FilePath]
missingMigrationsForSets sets =
  missingMigrationsForNames (migrationNamesForSets sets)

migrationStatusForNames :: [FilePath] -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatusForNames =
  Ledger.migrationStatusFor

migrationStatusForSet :: MigrationSet -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatusForSet set =
  migrationStatusForNames (migrationNames set)

migrationStatusForSets :: [MigrationSet] -> ConnectionString -> DiffTime -> IO MigrationStatus
migrationStatusForSets sets =
  migrationStatusForNames (migrationNamesForSets sets)
