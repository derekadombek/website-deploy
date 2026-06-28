# Infra — provisioning catalog

Terraform that stands up the hosting stack for each site. Two layers:

```
modules/aws/                 reusable building blocks (account-agnostic)
  static_site/                 private S3 + CloudFront (OAC) + bucket policy
  acm_certificate/             DNS-validated ACM cert (us-east-1)
  github_oidc/                 OIDC provider + deploy role + Terraform role
  static_site_stack/           BUNDLE: zone lookup + cert + static_site + DNS +
                               github_oidc, behind a manage_dns flag
envs/                        one dir per deployed site (concrete instances)
  _template/                   copy-me skeleton
  portfolio/                   derekadombek.com apex (your account)
  example-client/              foreign account + domain (validate-only example)
```

The namespace is `modules/<provider>/<capability>` so GCP/Azure or ECS/EKS stay
additive. **All account- and domain-specific values live in the env dir; the
modules never hardcode them.**

## Each env owns its own account boundary

- **`versions.tf`** declares the `backend "s3"` (state bucket + lock table, in
  that env's *own* account) and the two `aws` providers (default + `us_east_1`).
- **`main.tf`** calls `module "site" { source = "../../modules/aws/static_site_stack" }`
  with the per-site values and passes both providers in.

State is **per-env, per-account** — there is no shared state bucket across
accounts. Two envs in the *same* account may share a bucket with different keys.

## The auth model (no stored keys, ever)

Every account — yours or a client's — is self-contained. After a one-time
bootstrap it holds:

- **One GitHub OIDC provider** (account-global). Exactly **one env per account**
  sets `create_oidc_provider = true`; the rest set it `false` and reuse it.
- **Deploy role** — trusts the **app repo**, branch-scoped
  (`repo:<app>:ref:refs/heads/<branch>`); can only `s3 sync` + invalidate. Used
  on every push. Pair with branch protection on the app repo.
- **Terraform role** — trusts **this management repo** scoped to a GitHub
  **Environment** (`repo:derekadombek/website-deploy:environment:provisioning`),
  *not* a branch; manages the whole stack + that account's state. Standing but
  **inert**: the only token that satisfies its trust is one minted for a job
  that declared `environment: provisioning`, and that environment has required
  reviewers — so nothing broad runs without a human approval.

```
DEPLOY (everyday):  app repo push → OIDC → deploy role (target acct) → sync + invalidate
MANAGE (on demand): website-deploy workflow → approve env → OIDC → terraform role → apply
```

Keep the two trust targets distinct — collapsing them would let deploys and
provisioning share trust.

## Per-account onboarding (one-time bootstrap → OIDC-only thereafter)

The OIDC provider, roles, and state bucket don't exist in a brand-new account,
so OIDC can't get in yet. Exactly **one** privileged step bootstraps it; after
that the account is OIDC-only forever.

1. **Get one-time privileged access.** For a client: they grant you temporary
   admin/SSO access (or a technical client self-bootstraps). Configure a local
   AWS profile for it.
2. **Create the state backend** (bucket + DynamoDB lock table) in that account —
   an S3 backend can't bootstrap its own bucket. Use the helper:
   ```bash
   AWS_PROFILE=<client-bootstrap> \
     infra/scripts/bootstrap-backend.sh <state-bucket> <lock-table> <region>
   ```
   Use the same names in the env's `versions.tf` backend block + `tf_state_bucket`
   / `tf_lock_table`.
3. **Create the env dir.** Either run the **New site env** workflow in this repo
   (owner-only `workflow_dispatch` → opens a PR with the generated config), or
   generate it locally:
   ```bash
   infra/scripts/new-site.sh --name <site> --domain <domain> \
     --deploy-repo <owner/app-repo> --region <region> \
     --create-oidc-provider true   # true only for the account's first env
   ```
   (Or copy `infra/envs/_template` by hand.) Review the generated `main.tf` /
   `versions.tf` and commit them.
4. **Bootstrap apply** with the privileged profile:
   ```bash
   cd infra/envs/<site>
   terraform init
   terraform plan      # review
   terraform apply
   ```
5. **Set the repo Variables** from `terraform output` (see the table below), then
   **drop the privileged access.** From here on you manage the env from this
   repo via the Terraform role (OIDC, behind the `provisioning` approval) and
   the app repo deploys via the deploy role — nothing stored.

### Adding a client

Copy `_template`, point `deploy_github_repo` at the **client-owned** app repo
(they add you as admin → clean offboarding: they revoke your admin and delete the
two roles and you're fully out), keep `mgmt_github_repo = derekadombek/website-deploy`,
give the env its own account profile + state backend, and follow the bootstrap
steps above.

### DNS: client already on Route 53, or not yet

`manage_dns = true` needs a hosted zone for the domain. Two cases, one flag:

- **Client already uses Route 53** → leave `create_hosted_zone = false`. The module
  looks up the existing zone.
- **Client has no Route 53 zone yet** → set `create_hosted_zone = true`. The module
  creates the zone. Then delegation has to happen before ACM can validate, and how
  that's handled depends on where the domain is registered:
  - **Registered in Route 53 / Amazon Registrar (this account)** → also set
    `registrar_in_route53 = true`. The nameservers are set automatically — fully
    hands-off, a single `terraform apply` works.
  - **Registered elsewhere (GoDaddy, Namecheap, …)** → leave `registrar_in_route53`
    false and onboard with the babysitter script, which creates the zone, prints the
    nameservers, **waits for you/the client to paste them at the registrar**, then
    finishes the apply so it never hangs at cert validation:
    ```bash
    # first-ever provision of this env needs CONFIRM_FRESH=1 (guardrail below)
    CONFIRM_FRESH=1 AWS_PROFILE=<client-bootstrap> infra/scripts/onboard-site.sh <env-dir-name>
    ```
    (Re-runnable — if you bail during the wait, run it again and it resumes.)

> **Re-run guardrail.** With intact Terraform state, re-running bootstrap or
> onboard is a safe no-op (the backend creator skips existing resources; apply is
> declarative). The danger is a re-run that can't see its state (deleted/renamed
> state bucket, wrong backend) — Terraform would recreate everything and silently
> make a **duplicate Route 53 zone**. So `onboard-site.sh` / `aws-provision-site`
> **refuse to apply against empty state** unless `CONFIRM_FRESH=1` /
> `confirm-fresh: true`, which you set only for the genuine first run.

For a client keeping DNS elsewhere entirely (Cloudflare, etc.), use
`manage_dns = false` (ship the CloudFront default domain) and have them CNAME to it.

### One shared `provisioning` environment

All accounts' Terraform roles trust the same `environment:provisioning` subject, so a
**single** `provisioning` environment in this repo gates every client — and since each
client is its own `terraform.yml` matrix leg, each waits for its own approval. Only
make per-client environments (set `mgmt_environment` + a matching GitHub Environment)
if a client needs **different reviewers**.

## Repo Variables (Settings → Actions → Variables)

**App repo** (portfolio / a client repo) — consumed by the deploy action:

| Variable | Source (`terraform output`) |
|---|---|
| `AWS_REGION` | the env's provider region |
| `AWS_DEPLOY_ROLE_ARN` | `deploy_role_arn` |
| `S3_BUCKET` | `s3_bucket` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` |

**This repo** (website-deploy) — CI management is per **GitHub Environment**, one per
CI-managed env (named the same as the env dir). Each holds:

- **scoped variables** `AWS_TF_ROLE_ARN` (that env's `terraform_role_arn`) + `AWS_REGION`,
- its own **required reviewers** (the approval that mints the env-scoped OIDC token).

The env's Terraform config sets `mgmt_environment = "<name>"` so its role trusts
`environment:<name>`. **Convention: env dir name = GitHub Environment name = `mgmt_environment`.**

### Which envs CI runs

`terraform.yml` never plans/applies every env at once:

- **push / PR** → only the envs whose files changed (a `infra/modules/**` change counts
  as all, since modules are shared).
- **workflow_dispatch** → pick one env, or `all`.

Every env is **auto-validated**. An env becomes CI **plan/apply**-managed simply by having
a GitHub Environment with its name — that's the opt-in. So onboarding a client to CI is:
create the `<name>` environment, add `AWS_TF_ROLE_ARN` + `AWS_REGION` + reviewers (the
`register-ci-env.sh` script does this from `terraform output`).

## Verify

```bash
# Format + per-env validate:
terraform fmt -recursive -check
cd infra/envs/<env> && terraform init -backend=false && terraform validate

# Foreign-account example parses (not applied):
cd infra/envs/example-client && terraform init -backend=false && terraform validate
```
