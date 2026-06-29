# Actions catalog

Reusable GitHub composite actions for deploying apps to cloud hosting. Each
action is callable cross-repo as
`derekadombek/website-deploy/actions/<name>@<ref>` and stays thin for the caller:
the build runs **inside** the action.

The namespace mirrors the infra catalog — provider (`aws` today; `gcp`/`azure`
later) and capability (`static-site`; later `ecs`/etc.). Adding an action is
additive: drop a new `<name>/action.yml` here and document it below.

## `aws-static-site`

Optionally build a static site, then `aws s3 sync` + CloudFront invalidation,
authenticating keylessly via GitHub OIDC. Account-agnostic — role, bucket, and
distribution are inputs, so the same action deploys any site in any account.

### Inputs

| Input | Required | Default | Purpose |
|---|---|---|---|
| `aws-region` | yes | — | Region of the S3 bucket. |
| `role-arn` | yes | — | Deploy role to assume via OIDC. |
| `s3-bucket` | yes | — | Destination bucket name. |
| `cloudfront-distribution-id` | yes | — | Distribution to invalidate. |
| `source-dir` | yes | — | Directory synced to the bucket (`site`, `dist`, …). |
| `build-command` | no | `""` | Build command; skipped if empty. |
| `install-command` | no | `""` | Install command; skipped if empty. |
| `node-version` | no | `20` | Node version when building/installing. |
| `working-directory` | no | `.` | Where install/build run; `source-dir` resolves from here. |

### Caller requirements

The job **must** request the OIDC token and declare it deploys:

```yaml
permissions:
  id-token: write
  contents: read
```

The `role-arn` must trust the **calling repo's** OIDC subject (this repo's
Terraform provisions exactly such a deploy role per site).

### Example — build an Astro site and deploy

```yaml
name: Deploy
on:
  push:
    branches: [main]
  workflow_dispatch: {}

permissions:
  id-token: write
  contents: read

concurrency:
  group: deploy
  cancel-in-progress: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: derekadombek/website-deploy/actions/aws-static-site@v1
        with:
          aws-region: ${{ vars.AWS_REGION }}
          role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          s3-bucket: ${{ vars.S3_BUCKET }}
          cloudfront-distribution-id: ${{ vars.CLOUDFRONT_DISTRIBUTION_ID }}
          install-command: npm ci
          build-command: npm run build
          source-dir: dist
```

### Example — deploy pre-built files (no build)

```yaml
      - uses: actions/checkout@v4
      - uses: derekadombek/website-deploy/actions/aws-static-site@v1
        with:
          aws-region: ${{ vars.AWS_REGION }}
          role-arn: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          s3-bucket: ${{ vars.S3_BUCKET }}
          cloudfront-distribution-id: ${{ vars.CLOUDFRONT_DISTRIBUTION_ID }}
          source-dir: site
```

The four `vars.*` come from `terraform output` after provisioning the site (see
[`../infra/README.md`](../infra/README.md)).

---

## `aws-grant-access`

The **client onboarding** action — the only management action a client runs, once,
in **their** repo with **their** privileged creds. It stands up the trust
foundation so you can manage their account over OIDC afterward: creates the
Terraform state backend (AWS CLI), then applies the access Terraform (OIDC
provider + deploy role + management role) with state in that bucket. Nothing is
handed to you; from then on it's keyless.

| Input | Required | Default | Purpose |
|---|---|---|---|
| `aws-region` | yes | — | Region for the state + site buckets. |
| `project-name` | yes | — | Must match the site env's `project_name`. |
| `deploy-github-repo` | yes | — | App repo that deploys the site. |
| `mgmt-environment` | yes | — | GitHub Environment the management role trusts (= the site env name). |
| `state-bucket` | yes | — | State bucket to create. |
| `lock-table` | yes | — | Lock table to create. |
| `mgmt-github-repo` | no | `derekadombek/website-deploy` | Management repo. |
| `github-branch` | no | `main` | App repo deploy branch. |
| `role-arn` | no | `""` | Admin role to assume via OIDC; empty = creds from a prior step. |

**Auth:** runs *before* OIDC exists (it creates it), so supply privileged creds —
a prior `configure-aws-credentials` step (short-lived SSO/temp creds) or, if an
admin role already exists, `role-arn` (needs `permissions: id-token: write`).

```yaml
jobs:
  grant-access:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # configure the client's privileged creds here…
      - uses: derekadombek/website-deploy/actions/aws-grant-access@v1
        with:
          aws-region: us-east-1
          project-name: acme
          deploy-github-repo: acme/site
          mgmt-environment: acme
          state-bucket: acme-tf-state
          lock-table: acme-tf-locks
```

It outputs the deploy + management role ARNs. You then build the site over OIDC
via the **Provision Client's AWS Setup** workflow — there's no separate provision
action; the site env builds only the website, since the roles already exist in
the access config.

## Adding an action

1. Create `actions/<provider>-<capability>/action.yml` with `runs.using: composite`.
2. Keep it account-agnostic — take role/target resources as inputs, never hardcode.
3. Document its inputs + a caller snippet in a new section here.
4. Tag a release (e.g. `v1`) so callers can pin `@v1`.
