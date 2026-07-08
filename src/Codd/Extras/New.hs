module Codd.Extras.New
  ( MigrationFileConfig (..),
    defaultMigrationsDir,
    migrationFileName,
    migrationSlug,
    migrationTimestampPrefix,
    newMigrationFile,
  )
where

import Codd.Parsing (toMigrationTimestamp)
import Control.Monad (when)
import Data.Char (isAlphaNum, toLower)
import Data.List (isPrefixOf)
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

data MigrationFileConfig = MigrationFileConfig
  { migrationSlugPrefix :: Maybe String,
    migrationTemplate :: String -> String
  }

-- | Conventional package-local directory for SQL migrations.
defaultMigrationsDir :: FilePath
defaultMigrationsDir = "sql-migrations"

-- | Create a timestamped migration skeleton under @dir@.
newMigrationFile :: MigrationFileConfig -> FilePath -> String -> IO FilePath
newMigrationFile config dir description = do
  when (not (any isAlphaNum description)) $
    ioError (userError "migration description must contain at least one letter or digit")
  now <- getCurrentTime
  let path = dir </> migrationFileName config now description
  createDirectoryIfMissing True dir
  exists <- doesFileExist path
  when exists $
    ioError (userError ("refusing to overwrite existing migration: " <> path))
  writeFile path (migrationTemplate config description)
  pure path

-- | Build the migration filename from a timestamp and a description.
migrationFileName :: MigrationFileConfig -> UTCTime -> String -> FilePath
migrationFileName config now description =
  migrationTimestampPrefix now
    <> "-"
    <> migrationSlug (migrationSlugPrefix config) description
    <> ".sql"

-- | Format a codd-compatible UTC timestamp prefix.
migrationTimestampPrefix :: UTCTime -> String
migrationTimestampPrefix now =
  formatTime defaultTimeLocale "%Y-%m-%d-%H-%M-%S" rounded
  where
    (rounded, _) = toMigrationTimestamp now

-- | Turn a free-text description into a filename slug with an optional namespace.
migrationSlug :: Maybe String -> String -> String
migrationSlug prefix raw =
  case normalisedPrefix of
    Nothing -> slug
    Just prefix'
      | (prefix' <> "-") `isPrefixOf` slug -> slug
      | otherwise -> prefix' <> "-" <> slug
  where
    slug = normaliseSlug raw
    normalisedPrefix =
      case prefix of
        Nothing -> Nothing
        Just prefixRaw ->
          case normaliseSlug prefixRaw of
            "" -> Nothing
            prefix' -> Just prefix'

normaliseSlug :: String -> String
normaliseSlug raw =
  trimDashes (collapseDashes (map normalise raw))
  where
    normalise c = if isAlphaNum c then toLower c else '-'
    collapseDashes ('-' : '-' : rest) = collapseDashes ('-' : rest)
    collapseDashes (c : rest) = c : collapseDashes rest
    collapseDashes [] = []
    trimDashes = f . f where f = reverse . dropWhile (== '-')
