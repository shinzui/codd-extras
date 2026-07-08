# codd-extras

Small Haskell helpers for using [codd](https://github.com/mzabani/codd) with
compile-time embedded SQL migrations.

The package does not own any SQL schema. It provides reusable glue for packages
that embed their own `sql-migrations/` directory and want a consistent codd apply
path:

- parse embedded `[(FilePath, ByteString)]` migration files
- scaffold timestamped migration skeleton files
- apply one or more embedded migration groups through codd
- build small migration CLIs around `up`, `verify`, `status`, `new`, and `lock`
- lint migration filenames, bodies, and checksum manifests
- write `migrations.lock` checksum manifests from a migration directory
- force the single-try retry policy needed for in-memory migration streams
- serialize applies with a PostgreSQL advisory lock
- inspect codd's migration ledger
- materialize embedded expected-schema snapshots
- provision ephemeral PostgreSQL databases for tests and snapshot generation

## Package Layout

`codd-extras` has a main runtime library and one public sublibrary.

Main library modules:

- `Codd.Extras.Apply`
- `Codd.Extras.Cli`
- `Codd.Extras.Embedded`
- `Codd.Extras.ExpectedSchema`
- `Codd.Extras.Guards`
- `Codd.Extras.Ledger`
- `Codd.Extras.Lock`
- `Codd.Extras.LockFile`
- `Codd.Extras.New`
- `Codd.Extras.Settings`
- `Codd.Extras.Verify`

Public sublibrary:

- `codd-extras:ephemeral`
- `Codd.Extras.TestSupport`
- `Codd.Extras.WriteSchema`

Use the main library from migration runtimes. Use the `ephemeral` sublibrary only
from test-support or expected-schema writer executables.

## Basic Usage

Embed a package's migration directory and expose parsed migrations:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module MyApp.Migrations where

import Codd (ApplyResult, CoddSettings)
import Codd.Extras.Apply (applyEmbeddedMigrationsNoCheck)
import Codd.Extras.Embedded qualified as Embedded
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.Time (DiffTime)

myAppMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
myAppMigrations =
  Embedded.parseEmbeddedMigrations "MyApp" embeddedMigrationFiles

runMyAppMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runMyAppMigrationsNoCheck settings timeout =
  applyEmbeddedMigrationsNoCheck settings timeout [("MyApp", embeddedMigrationFiles)]

embeddedMigrationFiles :: [(FilePath, ByteString)]
embeddedMigrationFiles = $(embedDir "sql-migrations")
```

For services that compose framework migrations with their own migrations, keep the
existing parsed migration action and route the apply through `codd-extras`:

```haskell
import Codd.Extras.Apply (applyParsedMigrationsNoCheck)
import Data.Time (secondsToDiffTime)
import Framework.Migrations qualified as Framework

allMigrations = do
  framework <- Framework.allMigrations
  app <- myAppMigrations
  pure (framework <> app)

applyAllWithSettings settings =
  applyParsedMigrationsNoCheck settings (secondsToDiffTime 5) allMigrations
```

Both apply helpers take the same advisory lock and force codd's retry policy to a
single try. That avoids codd retrying an in-memory stream, which it cannot re-read.

## Settings From a Connection String

For no-check migration paths in tests or simple migration executables:

```haskell
import Codd.Extras.Settings (noCheckCoddSettings)

settings =
  noCheckCoddSettings ["myapp", "public"] connectionString
```

## Ledger Status

Use `Codd.Extras.Ledger` for read-only status checks:

```haskell
import Codd.Extras.Ledger qualified as Ledger

status <- Ledger.migrationStatusFor expectedMigrationNames connString timeout
print (Ledger.statusPending status)
```

The ledger helper understands both current `codd.sql_migrations` and older
`codd_schema.sql_migrations` ledgers.

## Migration Integrity Guards

Use `Codd.Extras.Guards` in test suites or lockfile writers to catch migration
drift before codd sees a database:

```haskell
import Codd.Extras.Guards

lintViolations
  LintConfig { requiredQualifier = "myapp.", exemptFiles = [] }
  embeddedMigrationFiles
```

The guard helpers can detect hand-assigned timestamp sentinels, duplicate
timestamp prefixes, unqualified DDL targets, unsafe `CONCURRENTLY` usage, and
`migrations.lock` checksum drift.

## Migration Scaffolding

Use `Codd.Extras.New` to create timestamped migration skeletons without applying
them:

```haskell
import Codd.Extras.New qualified as New

newMigrationFile
  New.MigrationFileConfig
    { New.migrationSlugPrefix = Just "myapp",
      New.migrationTemplate = \description ->
        "-- " <> description <> "\n\n-- TODO: write migration\n"
    }
  "sql-migrations"
  "add widget index"
```

The timestamp prefix uses codd's timestamp rounding, so generated filenames are
in the same `YYYY-MM-DD-HH-MM-SS-slug.sql` shape that codd parses and orders.

## Migration CLI Helpers

Use `Codd.Extras.Cli` when a migration package wants the standard operational
commands:

```haskell
import Codd.Extras.Cli (MigrationCliConfig (..), migrationCliMain)
import Data.Time (secondsToDiffTime)

main =
  migrationCliMain
    MigrationCliConfig
      { cliProgramName = "myapp-migrate",
        cliMigrationsDirEnv = "MYAPP_MIGRATIONS_DIR",
        cliDefaultMigrationsDir = "sql-migrations",
        cliNewMigrationFile = newMigrationFile,
        cliRunUp = runUp,
        cliVerifySchema = verifySchema,
        cliMigrationStatus = migrationStatus,
        cliConnectTimeout = secondsToDiffTime 5,
        cliNoCheckEnv = Nothing,
        cliEmbedRefreshHint =
          "Next: touch the module that embeds sql-migrations (or run `cabal clean`)."
      }
```

The CLI handles argument dispatch, status rendering, verify exit codes, no-check
environment parsing, migration scaffolding, and `migrations.lock` generation.
For packages that need only the lock writer, use `Codd.Extras.LockFile` directly.

## Expected Schema Helpers

If a package embeds a checked-in `expected-schema/` tree:

```haskell
{-# LANGUAGE TemplateHaskell #-}

import Codd.Extras.Verify (verifySchemaWith)
import Data.FileEmbed (embedDir)

expectedSchemaFiles = $(embedDir "expected-schema")

verifySchema =
  verifySchemaWith expectedMigrationNames expectedSchemaFiles "myapp-expected-schema"
```

To regenerate an expected-schema snapshot from a fresh ephemeral PostgreSQL
database, depend on `codd-extras:ephemeral` and use:

```haskell
import Codd.Extras.WriteSchema (writeExpectedSchemaMain)
import Data.Time (secondsToDiffTime)

main =
  writeExpectedSchemaMain "myapp" ["myapp"] "expected-schema" $ \settings ->
    runMyAppMigrationsNoCheck settings (secondsToDiffTime 5)
```

## Development

Build and test locally:

```sh
cabal build codd-extras
cabal test codd-extras:codd-extras-test
```

The test suite uses `ephemeral-pg`, so PostgreSQL tooling must be available in the
development environment.
