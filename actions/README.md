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

> The two actions below are **onboarding/management** actions, not the everyday
> deploy. They run privileged or Terraform-scoped operations — read the auth
> notes. Both wrap the scripts in [`../infra/scripts/`](../infra/scripts/).

## `aws-bootstrap-backend`

Create the Terraform state backend (S3 bucket + DynamoDB lock table) in a new
account — the one-time step that must happen before `terraform init`, since an S3
backend can't create its own bucket.

| Input | Required | Default | Purpose |
|---|---|---|---|
| `aws-region` | yes | — | Region for the bucket + table. |
| `state-bucket` | yes | — | Bucket name to create. |
| `lock-table` | yes | — | DynamoDB lock table to create. |
| `role-arn` | no | `""` | Role to assume via OIDC; empty = use creds from a prior step. |

**Auth:** this runs *before* the account has OIDC roles, so supply privileged
credentials — either a prior `configure-aws-credentials` step (short-lived
SSO/temp creds) or, if an admin role already exists, `role-arn` (needs
`permissions: id-token: write`).

```yaml
jobs:
  bootstrap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # configure privileged creds here (temp SSO creds, or an admin role)…
      - uses: derekadombek/website-deploy/actions/aws-bootstrap-backend@v1
        with:
          aws-region: us-west-2
          state-bucket: acme-tf-state
          lock-table: acme-tf-locks
```

## `aws-provision-site`

Provision/update one site's full stack by running Terraform against its env dir
in this repo, babysitting Route 53 delegation so the run never hangs at ACM
validation. The env must already exist under `infra/envs/`.

| Input | Required | Default | Purpose |
|---|---|---|---|
| `env` | yes | — | Env dir name under `infra/envs/`. |
| `aws-region` | yes | — | Region for the env. |
| `role-arn` | no | `""` | Env's Terraform role (OIDC) for ongoing management; empty = privileged creds for first bootstrap. |
| `terraform-version` | no | `1.5.7` | Terraform to install. |
| `confirm-fresh` | no | `false` | Set `true` **only** for the first-ever provision of this env (see guardrail below). |

**Auth:** first bootstrap → privileged creds in a prior step; ongoing management
→ `role-arn` = the env's `terraform_role_arn`, gated behind an approval
environment (`permissions: id-token: write`).

**Re-run guardrail:** the action **refuses to apply against empty Terraform
state** unless `confirm-fresh: true`. Empty state on a re-run means the state was
lost or the backend is mis-pointed, and applying would recreate resources and
silently create a **duplicate Route 53 zone**. So: pass `confirm-fresh: true` for
the very first provision; never again. Normal re-runs (intact state) are a safe
no-op and need nothing.

```yaml
jobs:
  provision:
    runs-on: ubuntu-latest
    environment: provisioning   # approval gate for the management case
    steps:
      - uses: actions/checkout@v4
      - uses: derekadombek/website-deploy/actions/aws-provision-site@v1
        with:
          env: example-client
          aws-region: us-east-1
          role-arn: ${{ vars.AWS_TF_ROLE_ARN_EXAMPLE_CLIENT }}
```

## Adding an action

1. Create `actions/<provider>-<capability>/action.yml` with `runs.using: composite`.
2. Keep it account-agnostic — take role/target resources as inputs, never hardcode.
3. Document its inputs + a caller snippet in a new section here.
4. Tag a release (e.g. `v1`) so callers can pin `@v1`.
