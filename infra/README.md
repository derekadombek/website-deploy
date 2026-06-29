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

Every account holds a GitHub **OIDC provider** + two roles:

- **Deploy role** — trusts the **app repo**, branch-scoped
  (`repo:<app>:ref:refs/heads/<branch>`); can only `s3 sync` + invalidate. Pair
  with branch protection on the app repo.
- **Terraform role** — trusts **this management repo** scoped to a GitHub
  **Environment** (`repo:derekadombek/website-deploy:environment:<env>`), *not* a
  branch; manages the site + that account's state. Standing but **inert**: the
  only token that satisfies its trust is one minted for a job that declared that
  environment, and the environment has required reviewers — so nothing runs
  without a human approval.

```
DEPLOY (everyday):  app repo push → OIDC → deploy role (target acct) → sync + invalidate
MANAGE (on demand): website-deploy workflow → approve env → OIDC → terraform role → apply
```

Keep the two trust targets distinct — collapsing them would let deploys and
provisioning share trust.

### One model: access config + site env

Every site — your own (e.g. `portfolio`) and clients alike — is onboarded the
same way. The **`aws-grant-access`** action runs once per account (with that
account's own creds) and stands up the trust foundation in the separate access
config (`infra/access`): the state backend + OIDC provider + deploy and
management roles, outputting the role ARNs. **No credentials are ever handed
over** — everything after is keyless over OIDC. The **site env** then builds only
the website (S3 / CloudFront / DNS) and authenticates via that OIDC.

## Onboarding (run once per site)

1. **Client runs `aws-grant-access`** (their repo, their creds) with the project
   name, region, their app repo, the `mgmt-environment` (= the site env name you'll
   use), and a state bucket/lock name. It stands up the trust foundation and prints
   the **deploy + management role ARNs**.
2. **You create the site env** — run the **New site env** workflow (or
   `new-site.sh --name <env> --domain …`), review the PR, merge. Point its
   backend at the state bucket from step 1.
3. **Register CI** — `register-ci-env.sh <env> <terraform-role-arn> <region>`
   (the role ARN + region are printed by aws-grant-access in step 1) creates the
   env's GitHub Environment, sets `AWS_TF_ROLE_ARN` + `AWS_REGION`, and adds you
   as reviewer.
4. **Provision the site** — over OIDC via `terraform.yml` (approve the env), or
   locally for the first apply with the DNS-delegation babysitting:
   ```bash
   CONFIRM_FRESH=1 infra/scripts/onboard-site.sh <env>
   ```
5. **Set the app repo's deploy Variables** — `AWS_DEPLOY_ROLE_ARN` (from step 1) +
   `S3_BUCKET` / `CLOUDFRONT_DISTRIBUTION_ID` (from the site `terraform output`) +
   `AWS_REGION`. Push → deploy.

Your **own** sites follow the same flow — run `aws-grant-access` once for the
account, then the site env builds the website over OIDC.

**Adding a domain later** — a site scaffolded with `manage_dns = false` serves the
CloudFront default URL. To attach a real domain, run the **Set site domain**
workflow (or `set-site-domain.sh <env> --domain <d> [--create-zone …]`), which
flips `manage_dns = true` + sets the domain in the existing env and opens a PR.
Merge, then re-provision — it's an additive in-place change (CloudFront gets the
alias + ACM cert; content untouched). Don't re-run New TF env; it won't overwrite
an existing env.

**Offboarding** is clean: the client deletes the access config (OIDC provider +
two roles + state) and revokes your admin on their app repo, and you're fully out
— nothing was ever stored on your side.

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
`register-ci-env.sh` script does this — pass it the role ARN + region that
aws-grant-access printed).

## Verify

```bash
# Format + per-env validate:
terraform fmt -recursive -check
cd infra/envs/<env> && terraform init -backend=false && terraform validate

# Foreign-account example parses (not applied):
cd infra/envs/example-client && terraform init -backend=false && terraform validate
```
