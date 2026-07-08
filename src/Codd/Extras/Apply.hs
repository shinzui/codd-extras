{-# LANGUAGE RankNTypes #-}

module Codd.Extras.Apply
  ( applyEmbeddedMigrations,
    applyEmbeddedMigrationsNoCheck,
    applyParsedMigrationsNoCheck,
  )
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings (..), VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Extras.Embedded (parseEmbeddedMigrations)
import Codd.Extras.Lock (withMigrationLock)
import Codd.Extras.Settings (forceSingleTryPolicy, warnRetryPolicyOverride)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Data.ByteString (ByteString)
import Data.Time (DiffTime)

applyEmbeddedMigrationsNoCheck ::
  CoddSettings ->
  DiffTime ->
  [(String, [(FilePath, ByteString)])] ->
  IO ApplyResult
applyEmbeddedMigrationsNoCheck settings connectTimeout groups = do
  let settings' = forceSingleTryPolicy settings
  warnRetryPolicyOverride settings
  withMigrationLock (migsConnString settings') connectTimeout $
    runCoddLogger $ do
      migrations <- traverse (uncurry parseEmbeddedMigrations) groups
      applyMigrationsNoCheck settings' (Just (concat migrations)) connectTimeout (const (pure SchemasNotVerified))

applyParsedMigrationsNoCheck ::
  CoddSettings ->
  DiffTime ->
  (forall m. (MonadFail m, EnvVars m) => m [AddedSqlMigration m]) ->
  IO ApplyResult
applyParsedMigrationsNoCheck settings connectTimeout loadMigrations = do
  let settings' = forceSingleTryPolicy settings
  warnRetryPolicyOverride settings
  withMigrationLock (migsConnString settings') connectTimeout $
    runCoddLogger $ do
      migrations <- loadMigrations
      applyMigrationsNoCheck settings' (Just migrations) connectTimeout (const (pure SchemasNotVerified))

applyEmbeddedMigrations ::
  CoddSettings ->
  DiffTime ->
  VerifySchemas ->
  [(String, [(FilePath, ByteString)])] ->
  IO ApplyResult
applyEmbeddedMigrations settings connectTimeout verifySchemas groups = do
  let settings' = forceSingleTryPolicy settings
  warnRetryPolicyOverride settings
  withMigrationLock (migsConnString settings') connectTimeout $
    runCoddLogger $ do
      migrations <- traverse (uncurry parseEmbeddedMigrations) groups
      applyMigrations settings' (Just (concat migrations)) connectTimeout verifySchemas
