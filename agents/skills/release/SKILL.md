---
name: release
description: Release the codd-extras package to Hackage following PVP
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# Release Skill

Release the single **`codd-extras`** package from this repository to
[Hackage](https://hackage.haskell.org/) using the Haskell **PVP** version
scheme (`A.B.C.D`).

## Package

This repo contains exactly one publishable cabal package:

- **`codd-extras`** — `./codd-extras.cabal` (repo root).

What ships and what does not:

- The public sublibrary **`ephemeral`** (`ephemeral/`, `library ephemeral`
  with `visibility: public`) **is published** — but as part of the
  `codd-extras` package, not as a standalone Hackage package. It is included in
  the same `cabal sdist` tarball automatically and shares codd-extras's version.
  On Hackage it appears under the codd-extras package page, and downstream
  consumers depend on it as `codd-extras:ephemeral`. It needs **no separate
  upload** — publishing codd-extras publishes it.
- The **`codd-extras-test`** test-suite is internal and is **never** published.

There is no multi-package dependency order to worry about: one package (with its
public `ephemeral` sublibrary), one version, one upload.

> **Dependency note:** `codd-extras` depends on `codd` and (via the `ephemeral`
> sublibrary) on `ephemeral-pg`. Locally these resolve through `cabal.project`
> (a `source-repository-package` for `codd`, and a local path for
> `ephemeral-pg`). For the uploaded package to build on Hackage's doc builder
> and for consumers, the versions matching the cabal bounds
> (`codd >=0.1.8 && <0.2`, `ephemeral-pg >=0.2 && <0.3`) must already be
> published to Hackage. Confirm this before publishing.

## Versioning Strategy

The Haskell PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports, new
  modules, new instances).
- `D` — **patch**: bug fixes, documentation, internal-only changes,
  performance improvements.

A single annotated git tag `v<version>` marks each release, and a matching
GitHub release is published.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — specifies the bump level explicitly.
- If omitted, determine the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from `codd-extras.cabal` (the `version:` field).
- Find the latest git tag matching `v*` to identify the last release point:
  `git tag --list 'v*' --sort=-v:refname | head -1`.
  - **First release:** if there are no `v*` tags yet, treat the entire history
    as the release contents and use `git log --oneline` for the summary.
- Otherwise run `git log --oneline <last-tag>..HEAD` to list commits since the
  last release. If there are no commits since the last tag, tell the user there
  is nothing to release and stop.

Present a summary: current version, last release tag (or "none — first
release"), and the commits to be included.

### 2. Determine the next version using PVP

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise analyze the commits to propose a bump:
  - "breaking", "remove", "rename", "change type", `!`/`BREAKING CHANGE` → major
  - "add", "new", "feat", "export" → minor
  - "fix", "docs", "refactor", "chore", "internal", "perf" → patch
- Present the proposed bump to the user and **ask for confirmation** before
  proceeding.

Increment the version (`A.B.C.D`):

- **major**: increment `B`, reset `C` and `D` to 0 (e.g. `0.1.0.0` → `0.2.0.0`).
- **minor**: increment `C`, reset `D` to 0 (e.g. `0.1.0.0` → `0.1.1.0`).
- **patch**: increment `D` (e.g. `0.1.0.0` → `0.1.0.1`).

### 3. Update the version and changelog

#### Version update

- Edit `codd-extras.cabal` and set the `version:` field to the new version.

#### Changelog update

- If `CHANGELOG.md` does not exist yet (it does not, as of the first release),
  create it with a top-level header and a section for the new version.
- Add a new section for the new version **above** any previous entries, using
  today's date in `YYYY-MM-DD` format:

  ```markdown
  ## <version> — YYYY-MM-DD
  ```

- If an "Unreleased" section exists, move its content into the new version
  section.
- Summarize the commits since the last release, grouped into only the
  categories that have entries:
  - **Breaking Changes** (major)
  - **New Features** (minor or major)
  - **Bug Fixes**
  - **Other Changes** (docs, refactoring, internal)

Show the user **all** changes (version bump + changelog) for review before
committing.

### 4. Verify (all gates are mandatory)

Run each of these and require it to pass before publishing. Stop and report on
any failure:

1. `nix fmt` — format the tree (treefmt: fourmolu, cabal-fmt, nixpkgs-fmt) and
   ensure it is clean.
2. `cabal build all` — the build must succeed.
3. `cabal test` — the `codd-extras-test` test-suite must pass.
4. `nix flake check` — treefmt + pre-commit hooks must pass.
   - Newly created files (e.g. a brand-new `CHANGELOG.md`) must be `git add`-ed
     first, since nix evaluates the git tree.

### 5. Commit, tag, and push

- Stage the modified `codd-extras.cabal` and `CHANGELOG.md`.
- Create a single commit with a Conventional Commits message:
  `chore(release): <new-version>` (project convention — see global CLAUDE.md).
  The body should summarize what's in the release and why this bump was chosen.
- Create an annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push both: `git push && git push --tags`.

The commit and tag must only be created **after** user approval of all changes.

### 6. Publish to Hackage

From the repo root:

1. `cabal check` — verify no packaging issues.
2. `cabal sdist` — build the source tarball (this bundles the `ephemeral`
   public sublibrary automatically), then
   `cabal upload --publish <tarball-path>` to publish it.
3. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`
   — build the docs, then
   `cabal upload --publish --documentation <docs-tarball-path>` to publish them.
4. Report the Hackage URL:
   `https://hackage.haskell.org/package/codd-extras-<version>`.

> Use `cabal upload` (without `--publish`) first if you want to stage a
> candidate for inspection; `--publish` is irreversible.

### 7. Create the GitHub release

After the Hackage upload succeeds, create a GitHub release for the tag:

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Hackage

https://hackage.haskell.org/package/codd-extras-<version>

## What's Changed

<changelog entries for this version from CHANGELOG.md>
EOF
)"
```

- Use the `CHANGELOG.md` entries for the release notes body.
- Report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and changelog before
  committing.
- Never skip the gates: `nix fmt`, `cabal build all`, `cabal test`, and
  `nix flake check` must all pass before publishing.
- If any step fails (including `nix flake check`), stop and report the error
  rather than continuing.
- Publishing to Hackage with `--publish` is irreversible — do not run it until
  the build/test/check gates are green and the user has approved.
- The commit and tag must only be created after user approval of all changes.
- Confirm `codd` and `ephemeral-pg` are available on Hackage at the required
  bounds before publishing, or the uploaded package's docs build and downstream
  consumers will fail.
