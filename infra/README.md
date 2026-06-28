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
2. **Create the state backend** (bucket + DynamoDB lock table) in that account,
   matching the names you'll put in `versions.tf` / `tf_state_bucket` /
   `tf_lock_table`.
3. **Copy the template and fill it in:**
   ```bash
   cp -r infra/envs/_template infra/envs/<site>
   # edit infra/envs/<site>/versions.tf  (backend + provider profile + region)
   # edit infra/envs/<site>/main.tf       (project_name, site_domain, repos, …)
   ```
   Set `create_oidc_provider = true` only if this is the account's first env.
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

## Repo Variables (Settings → Actions → Variables)

**App repo** (portfolio / a client repo) — consumed by the deploy action:

| Variable | Source (`terraform output`) |
|---|---|
| `AWS_REGION` | the env's provider region |
| `AWS_DEPLOY_ROLE_ARN` | `deploy_role_arn` |
| `S3_BUCKET` | `s3_bucket` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` |

**This repo** (website-deploy) — consumed by `terraform.yml`: a per-env
`AWS_TF_ROLE_ARN_<ENV>` (e.g. `AWS_TF_ROLE_ARN_PERSONAL_PORTFOLIO`) set from each env's
`terraform_role_arn`.

## Verify

```bash
# Format + per-env validate:
terraform fmt -recursive -check
cd infra/envs/<env> && terraform init -backend=false && terraform validate

# Foreign-account example parses (not applied):
cd infra/envs/example-client && terraform init -backend=false && terraform validate
```
