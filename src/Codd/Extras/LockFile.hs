module Codd.Extras.LockFile
  ( readMigrationSourcesFromDir,
    writeMigrationLock,
  )
where

import Codd.Extras.Guards (renderChecksumManifest)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isSuffixOf, sort)
import Data.Text.IO qualified as TIO
import System.Directory (listDirectory)
import System.FilePath ((</>))

readMigrationSourcesFromDir :: FilePath -> IO [(FilePath, ByteString)]
readMigrationSourcesFromDir dir = do
  names <- filter (".sql" `isSuffixOf`) <$> listDirectory dir
  traverse readSource (sort names)
  where
    readSource name = do
      bytes <- BS.readFile (dir </> name)
      pure (name, bytes)

writeMigrationLock :: FilePath -> FilePath -> IO Int
writeMigrationLock migrationsDir outputFile = do
  sources <- readMigrationSourcesFromDir migrationsDir
  TIO.writeFile outputFile (renderChecksumManifest sources)
  pure (length sources)
