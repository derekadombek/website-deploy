# Changelog

Every release is a `vX.Y.Z` tag (never moved) plus a GitHub Release with this
section as its notes. `v1` follows the latest `v1.x.y` for anyone who wants it, but
installs pin an exact version (see *Releases and upgrades* in the README).

**Upgrade notes** list anything a caller has to do: re-run grant-access, change a
client file, edit a client-repo workflow. No notes = bump the pin and Provision.

Format: newest first. Unreleased changes go under `## Unreleased` until tagged.

## Unreleased

## v1.0.0

First versioned release: everything up to the previous `v1` tag, plus the client-repo
template without a lock table.

- One client file per client (`clients/<name>.yaml`) in a private clients repo that
  calls this package's reusable workflows: Provision, Teardown, Unlock, Set CI
  Environment.
- *Grant AWS access* creates three roles per client account: read-only `-plan`,
  environment-gated `-terraform`, and `-github-deploy` (classic and immutable
  GitHub subjects).
- Provision plans every client (or one) and applies only with `apply` ticked. It
  handles DNS from the client file (existing zone, Route 53 registrar, outside
  registrar, `delegate_from`) and removes a stale delegation NS record.
- Per-client `state_lock: dynamodb | both | s3` (S3 lockfile replaces the
  deprecated DynamoDB lock).
- Client-repo `grant-access.yml` template: `lock-table` blank by default (no table).
- Provision ends each applied client with a health check (its domain answers over
  HTTPS); releases via `release.yml` and this changelog.
- Grant-access turns on state-bucket versioning, encryption and the public-access
  block for a reused bucket too, not only one it creates.

**Upgrade notes** (from the old floating `v1`):
- Pin `@v1.0.0` (and `package_ref: v1.0.0`) instead of `@v1`; add `renovate.json`
  (README → *Releases and upgrades*).
- A client whose state bucket existed before grant-access: re-run grant-access once
  so the bucket gets versioning.
- Clients still on `state_lock: dynamodb`: follow the switch steps in
  `clients/README.md`. Client repos with an older `grant-access.yml` copy the
  current template, or they can't drop the lock table.
