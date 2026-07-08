# codd-extras Design

`codd-extras` is a small adapter package around
[`codd`](https://github.com/mzabani/codd). It exists so packages can embed their
own SQL migrations, compose those migrations with migrations from other packages,
and run the result through codd consistently.

The package intentionally does not own schema definitions or SQL migrations. A
consumer package owns its `sql-migrations/` directory, expected-schema snapshots,
and the release policy for those files. `codd-extras` only provides shared glue
for the parts that are easy to duplicate incorrectly.

## Use Cases

### Package-owned embedded migrations

A library, framework, or service can embed its own migration directory at compile
time and expose a migration action. This is useful when the package should carry
the exact SQL needed for the version of the package being compiled.

The main library accepts embedded files as plain `[(FilePath, ByteString)]`
values. Callers can use `file-embed`, another embedding mechanism, or a
hand-built value in tests. Keeping the public API at this level avoids making
the runtime library depend on Template Haskell or a specific embedding package.

### Composed service migrations

Services often need to run migrations from more than one source. For example, a
framework package may create shared tables while the service package creates its
own application tables.

`codd-extras` supports passing multiple embedded migration groups or one already
parsed migration action. The groups are parsed and then applied in one codd run,
which means codd owns ordering, ledger updates, and skip behavior. This keeps the
database with one migration ledger instead of one ledger per package.

### Test databases

The `codd-extras:ephemeral` sublibrary provides helpers for creating a temporary
PostgreSQL database, applying migrations, running a test action, and stopping the
database afterwards.

This is separated from the main library so production migration code does not
pull in `ephemeral-pg` or PostgreSQL process-management dependencies.

### Expected-schema verification

Packages that check in codd expected-schema snapshots can embed those snapshots
and verify them against a migrated database. The package also provides a writer
helper for regenerating an expected-schema tree from a fresh ephemeral database.

The writer pins the PostgreSQL user supplied by the caller so generated role and
owner output stays deterministic across machines.

### Operational status checks

`Codd.Extras.Ledger` exposes read-only helpers for inspecting the codd migration
ledger and reporting which expected migration names are still pending. This is
intended for health checks, CLI status commands, or deploy tooling that needs an
answer without applying migrations.

### Migration integrity checks

Migration packages can use `Codd.Extras.Guards` from test suites or lockfile
writer executables to catch mistakes before a database is touched. The helpers
check timestamp-shaped filenames, duplicate timestamp prefixes, body-level SQL
heuristics such as schema-qualified DDL targets, and checksum manifests for
embedded migration files.

## Design Decisions

### codd remains the migration engine

The package delegates parsing, ordering, applying, ledger writes, and
expected-schema behavior to codd. It does not introduce a second migration
format, a second ledger, or a wrapper-specific migration lifecycle.

This matters for composed migrations: framework and service migrations are
combined into one codd invocation, and codd sorts and skips migrations using its
normal rules.

### Embedded files are a transport format

The embedded API accepts `[(FilePath, ByteString)]` instead of requiring a
specific compile-time embedding library. This keeps the dependency surface small
and lets each package decide how files are embedded.

Callers should still treat migration filenames as globally meaningful within a
composed migration set. Duplicate or confusing names make ledger inspection and
operational debugging harder.

### Integrity guards stay heuristic

The migration body linter intentionally uses simple statement-level heuristics
instead of a PostgreSQL parser. Its job is to catch common authoring mistakes in
test suites, such as unqualified DDL targets or `CONCURRENTLY` without a codd
no-transaction marker. codd remains responsible for parsing and applying
migrations.

### Parsed migration actions are first-class

Some packages already expose migrations as:

```haskell
(MonadFail m, EnvVars m) => m [AddedSqlMigration m]
```

The parsed apply helpers preserve that shape so those packages can compose
migrations without converting back to files. The embedded helpers are a
convenience layer over the same idea.

### Apply helpers take a database lock

Every apply helper runs under a PostgreSQL advisory lock. That protects services
from running two migration apply processes against the same database at the same
time.

The lock is intentionally outside codd's migration call so all composed
migrations share the same critical section.

### Retry policy is forced to one try

The apply helpers force codd's retry policy to `singleTryPolicy`. Embedded
migrations are in-memory streams, and codd cannot safely re-read those streams
after a retry. If a caller supplied a different retry policy, the helpers warn
and replace it.

Retrying the whole migration command should be handled by the caller or deploy
system after the process exits.

### Settings helpers stay narrow

`noCheckCoddSettings` builds the small subset of `CoddSettings` needed by
no-check migration executables and tests. It wraps codd's connection-string
parser instead of parsing libpq strings itself.

The helper accepts a schema list even for no-check flows so call sites can keep
the same shape when they later add expected-schema verification.

### Ledger detection follows codd

`Codd.Extras.Ledger` uses codd's own ledger detection instead of probing schema
tables by hand. It understands both the current `codd.sql_migrations` ledger and
older `codd_schema.sql_migrations` ledgers.

For ledger versions that record failed no-transaction migrations, the helper
filters out rows with `no_txn_failed_at` set. Those rows are not treated as
successfully applied migrations.

### Expected-schema materialization is temporary

Embedded expected-schema files are written to a temporary directory before codd
verifies them. That lets packages keep expected schema snapshots embedded in the
binary while still using codd's existing filesystem-based verification path.

The temporary directory label is caller supplied so failure messages and
debugging output can identify which package's expected schema was materialized.

## Non-goals

`codd-extras` is not a migration DSL, scaffolder, or schema ownership layer. It
does not generate SQL migrations, choose migration names, or enforce a project's
directory layout.

It also does not isolate framework and service ledgers. The intended model is
one composed migration set and one codd ledger per database.

Finally, it does not replace codd expected-schema behavior. It only bridges
embedded files and ephemeral database workflows into codd's existing APIs.

## Consumer Guidance

Use the main `codd-extras` library from runtime migration code. Depend on the
`codd-extras:ephemeral` sublibrary only from tests or snapshot writer
executables.

When using compile-time embedding, remember that adding a new SQL file may
require recompiling the module that embeds the migration directory. In some
build setups, touching that module is the simplest way to force recompilation.

For composed migrations, keep names unique and stable across all participating
packages. codd records migration names in the ledger, so renaming an existing
migration should be treated as a migration-history change, not a cosmetic edit.
