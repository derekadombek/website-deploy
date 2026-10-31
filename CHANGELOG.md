# Changelog

Every release is a `vX.Y.Z` tag (never moved) plus a GitHub Release with this
section as its notes. `v1` follows the latest `v1.x.y` for anyone who wants it, but
installs pin an exact version (see *Releases and upgrades* in the README).

**Upgrade notes** list anything a caller has to do: re-run grant-access, change a
client file, edit a client-repo workflow. No notes = bump the pin and Provision.

Format: newest first. Unreleased changes go under `## Unreleased` until tagged.

## Unreleased

## v1.7.2

- *Provision*: a failed hosted-zone step now stops the run with an error. Before, its
  output and failure were hidden, the NS delegation was skipped, and the apply hung on
  certificate validation. Terraform's output for that step now shows in the log.

## v1.7.1

- *Offboard Client's AWS Account*: its last job can be re-run. It skips an environment
  that's already deleted and reuses an already-pushed `offboard-<client>` branch (and its
  PR, if open) instead of failing.

**Upgrade notes:**
- `REGISTER_CI_TOKEN` needs one more permission on the clients repo: Pull requests,
  Read and write (to open the removal PR).

## v1.7.0

- *Offboard Client's AWS Account*: also opens the PR that removes `clients/<name>.yaml`,
  with the client dropdowns already updated, so it's ready to merge. Uses
  `REGISTER_CI_TOKEN` (already has Contents and Workflows write since v1.5.0).
- New `already_disconnected` input: when the client already removed the roles (the
  Disconnect link, or by hand), skips the AWS steps and only removes the environment
  and client file. A failed sign-in without it says so. The owner/confirm guard moved
  to the first job.

**Upgrade notes:**
- Clients repo `offboard.yml`: add an `already_disconnected` boolean input and pass it.

## v1.6.1

- *Offboard Client's AWS Account*: deletes the GitHub Environment in a separate job.
  Deleted from the job that ran in it, GitHub recreated it (empty) when that job ended.

## v1.6.0

- *Offboard Client's AWS Account* (`offboard-client-aws.yml`, reusable): removes your
  access when a client leaves, keeping their site running and their state bucket.
  Deletes the access roles by name (not Onsyte's), locks and empties
  `<client>-terraform`, writes `OFFBOARDED.md` to the state bucket, deletes the GitHub
  Environment and prints a note for the client. Refuses a client that others
  delegate DNS from.

**Upgrade notes:**
- Clients repo: add `offboard.yml` (calls this; pass `REGISTER_CI_TOKEN` so it can
  delete the environment).

## v1.5.1

- *Sync Client Dropdowns*: skips quietly when the PR's branch is already gone (merged
  and deleted before it started) instead of failing at checkout.

## v1.5.0

- *Sync Client Dropdowns* (`sync-client-dropdowns.yml`, reusable): on a clients-repo PR
  that changes `clients/`, rewrites every workflow's `client` dropdown to match the
  client files (keeping "all" where there is one) and pushes that to the PR's branch.
  New `client_dropdowns_sync` / `client_dropdown_names` in `lib/client.sh`; the
  existing check is unchanged.

**Upgrade notes:**
- Clients repo: add `sync-dropdowns.yml` (calls this on `pull_request` for `clients/**`).
  Give `REGISTER_CI_TOKEN` two more permissions on the clients repo: Contents and
  Workflows, both Read and write (GitHub's own token can't push workflow changes).

## v1.4.0

- One-click Connect AWS: the CloudFormation template a client creates from
  a link (`infra/onboarding/connect-aws.yaml`: a temporary, expiring
  `<client>-onboarding` role for the clients repo, plus the GitHub OIDC provider if
  missing), `publish-onboarding-template.sh` (puts a release's template in a public
  S3 bucket) and `onboarding-link.sh` (prints a client's link).
- *Onboard Client's AWS Account* (`onboard-client-aws.yml`, reusable): signs in through
  the onboarding role, runs `grant-access.sh` with everything taken from the client file
  (app repo and its ids, state bucket, lock table, delegation zone), deletes the
  onboarding stack, then removes the onboarding role with the client's Terraform role
  (a role can't delete itself, so the stack keeps it). *Grant AWS access* is unchanged and stays as the fallback.

**Upgrade notes:**
- Clients repo: add `onboard.yml` (calls this workflow; its `client` dropdown must list
  the same clients as the others). For private app repos, add the `APP_REPO_READ_TOKEN`
  secret (fine-grained PAT, All repositories or the app repos, Metadata: Read-only;
  add Metadata by hand on the token page or the repository access won't save).
- Publish this version's template: `publish-onboarding-template.sh v1.4.0`.

## v1.3.0

- Onsyte (`next_app`) can send email: an SES identity for `<onsyte_subdomain>.<domain>`
  with DKIM, a `mail.` MAIL FROM subdomain (SPF) and a report-only DMARC record, all in
  the app's zone. The Lambda may send only as `no-reply@<that domain>`. The `onsyte`
  output gains `mail_from`. Used for password-reset emails (Onsyte v0.4.0).
- Terraform role: manage SES identities, read the account's SES status. Plan role:
  read them.

**Upgrade notes:**
- Re-run *Grant AWS access* for every Onsyte client (new SES permissions) before the
  first Provision on this version.
- Provision adds 6 DNS records and the SES identity per Onsyte install.
- One-time per install: Supabase sign-up off, and SES production access (`clients/README.md`,
  "Onsyte installs: one-time steps"). Deploy Onsyte in the clients repo needs the matching
  update (sets `MAIL_FROM` / `APP_URL`, checks both).

## v1.2.0

- Client file: `site: false` for a client whose website is hosted elsewhere and who
  only gets Onsyte here. No static site and no `app_repo`; Onsyte gets its own zone
  (`hosted_zone`, default `<onsyte_subdomain>.<domain>`), delegated with 4 NS records at
  their DNS provider. Provision's health check checks Onsyte's address for them, and
  Teardown reminds you to have the NS records removed.
- *Grant AWS access*: `deploy-github-repo` is optional; without it no deploy role is
  made. New template `templates/access-repo` for clients with no app repo.
  Both templates point to the steps for turning on IAM Identity Center in a new account
  (its access portal gives the short-lived admin keys).
- New script helper `client_zone` (the zone a client's records go in), used everywhere
  the zone name was worked out by hand.

**Upgrade notes:**
- The site stack moves from `module.site` to `module.site[0]` (a `moved` block does it).
  The first Provision after upgrading lists every existing client as having changes:
  only "has moved" lines, 0 to add/change/destroy. Apply once to save the move. Don't
  change a client's domain in that same run: the zone step can't run until the move is
  applied.
- Re-running *Grant AWS access* with this version moves the deploy role the same way;
  no changes. Nothing else to do.

## v1.1.0

- New module `infra/modules/aws/next_app`: a Next.js app built with OpenNext, served
  by CloudFront → API Gateway (HTTP API) → Lambda, static files from a private S3
  bucket, with its own cert and DNS records in the client's zone. Terraform builds
  the infrastructure only; a deploy workflow ships the code and its settings, so
  they never land in Terraform state.
- Client file: `onsyte_subdomain` installs Onsyte at `<onsyte_subdomain>.<domain>`.
  The site root's new `onsyte` output tells the deploy workflow where to ship.
- *Grant AWS access*: the `-terraform` role can manage Lambda functions, log groups
  and API Gateway, and pass `<client>-*` roles to Lambda; the `-plan` role can read
  them.
- New provider in the site root: `hashicorp/archive` (the Lambda placeholder zip).

**Upgrade notes:**
- A client getting `onsyte_subdomain`: re-run *Grant AWS access* with this version
  first, or Provision's apply fails on the new permissions. Other clients: nothing.

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
