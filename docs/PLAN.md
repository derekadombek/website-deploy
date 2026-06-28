# Plan: Turn `website-deploy` into a reusable, multi-account, multi-domain deploy catalog

> **Status: design record — Phase 1 not yet built.** Auth model converged on a single
> GitHub-OIDC, per-account-isolated design (no ops account / assume-role / ExternalId).

## Context

`website-deploy` (`github.com/derekadombek/website-deploy`) currently does two things hard-wired
to one demo site, **Bob's Fishing Tours** (`bob.derekadombek.com`):

1. **Provisions** AWS hosting via Terraform (`infra/`): private S3 + CloudFront (OAC) + ACM cert
   + Route 53 alias + GitHub OIDC roles, from three modules (`static_site`, `acm_certificate`,
   `github_oidc`). Root `infra/main.tf` + all defaults are baked to Bob's, and it assumes **one
   AWS account + one shared state bucket + one account-global OIDC provider**.
2. **Deploys** (`.github/workflows/deploy.yml`): `aws s3 sync site/ …` + CloudFront
   invalidation, keyless via OIDC.

**Goal:** a reusable toolkit so *any* repo deploys an app by calling a shared GitHub Action with
inputs. First dogfood target: the **portfolio** repo (`github.com/derekadombek/portfolio`,
Astro → `dist/`).

**Hard constraints (from user):**
- **Multi-domain:** every site has its own domain + its own Route 53 hosted zone. Apex
  `derekadombek.com` is the **portfolio only**; Bob's is `bob.derekadombek.com`. **Clients each
  get a different domain — nothing shared under the user's domain.** `site_domain` +
  `hosted_zone_name` are strictly per-env.
- **Multi-account:** clients live in **different AWS accounts**. No shared state bucket, no
  account-global OIDC provider assumed. Provider config + state backend are **fully per-env**.
- **Catalog intent:** namespaced by provider (AWS now; GCP/Azure later) and capability
  (static-site/S3, DNS, bundled, later ECS/EKS/AKS). Implement the AWS static-site path fully;
  adding providers/capabilities stays additive.
- **Reusable unit:** a **composite action** callable cross-repo as
  `derekadombek/website-deploy/actions/<name>@<ref>`. Build happens *inside* the action (optional
  `build-command`/`install-command`/`node-version`) so callers stay thin.
- **Scope:** Phase 1 provisions the user's own sites (portfolio apex + Bob's) now, **and**
  scaffolds a validate-only client env example (foreign account + foreign domain) + a `_template`
  env. Phase 2 (onboarding automation) is documented but **not built yet**.

## THE AUTH MODEL (converged — single design)

> Earlier drafts weighed "Model A (central ops + assume-role)" vs "Model B (isolated)". **Both are
> dropped** in favor of one model below. There is **no ops AWS account, no `assume_role` chain, no
> ExternalId, and no stored credentials anywhere.** GitHub OIDC federates *directly* into each
> account.

**Every account (yours OR a client's) is self-contained.** At onboarding it gets, all in that
account:
- **GitHub OIDC provider** (one per account).
- **Deploy role** — trust policy keyed to the **app repo's** OIDC `sub`
  (`repo:<owner>/<apprepo>:…`); permissions = S3 sync + CloudFront invalidation only.
- **Terraform/provisioner role** — trust policy keyed to the **`website-deploy` repo's** OIDC
  `sub` **scoped to a GitHub Environment** (`repo:derekadombek/website-deploy:environment:provisioning`),
  NOT a branch; permissions = manage the stack (s3/cloudfront/acm/route53 + scoped IAM + that
  account's state bucket/lock).
- **Its own Terraform state** bucket + DynamoDB lock (in that same account).

```
DEPLOY (everyday):   app repo push → GitHub OIDC → deploy role (target acct) → s3 sync + invalidate
MANAGE (on demand):  website-deploy workflow → GitHub OIDC → terraform role (target acct) → apply
```

**Repo ownership:** the **client owns their app repo and adds you as an admin.** OIDC trust binds
to the repo identity, not a person, so you (as admin) manage the deploy workflow + repo Variables +
branch protection and trigger deploys, while the client retains ownership → clean offboarding
(client revokes your admin + deletes the two roles and you're fully out). `github_repo` is a
per-env Terraform input, so the deploy role's trust can point at the client repo while the
terraform role points at `website-deploy`.

**Your own sites (portfolio, Bob's)** are the *same* model pointed at your own account — no special
case; the app repo and the management repo both happen to be yours.

**Security hardening (decided):** the two roles are scoped differently to match their risk:
- **Deploy role** → branch-scoped (`…:ref:refs/heads/main`) + branch protection on the app repo →
  **auto** on push (deploys are frequent, low-privilege).
- **Terraform/mgmt role** (broad) → **GitHub Environment-scoped** (`…:environment:provisioning`).
  The provisioning workflow job declares `environment: provisioning`, which has **required
  reviewers = you**. Flow: trigger infra change → GitHub pauses for your approval → only then is the
  environment-scoped OIDC token minted → only that token satisfies the role's trust → Terraform
  runs. The broad role is **unusable without a human approval**, even though it's standing — this is
  what neutralizes the bootstrap/management role's power.

### First-trust (the one irreducible manual step, once per new account)
The OIDC provider + roles + state bucket don't exist yet in a brand-new account, so GitHub OIDC
can't get in yet — the **account owner must grant one-time privileged access** to create them.
Default per user: **client grants one-time admin/SSO access**; you run the bootstrap `terraform
apply` once, then drop the access. (Self-bootstrap by a technical client is a documented
alternative.) After this single apply, the account is **OIDC-only forever** — you manage via the
`website-deploy` repo, deploys run from the app repo, nothing stored, revoke by deleting roles.

## Auth flow — how a repo authenticates to AWS (no stored keys)

On any run, GitHub mints a short-lived OIDC JWT (`sub = repo:<owner>/<repo>:ref:…` or
`…:environment:<env>`, `aud = sts.amazonaws.com`). `aws-actions/configure-aws-credentials@v4`
calls STS `AssumeRoleWithWebIdentity` with that JWT + the role ARN; AWS validates
provider/`aud`/`sub` against the role's trust policy and returns 15–60 min temp creds. The deploy
workflow uses them to sync+invalidate; the management workflow uses them to run Terraform. The
role lives in the **target account**, so federation is **GitHub → that account directly**.

## Target structure (`website-deploy` repo)

```
actions/                              # CATALOG of reusable composite actions
  aws-static-site/action.yml          # NEW: optional build → S3 sync → CloudFront invalidate
  README.md                           # NEW: catalog index + caller snippet + extension points
.github/workflows/
  deploy.yml                          # EDIT: Bob's deploy now `uses: ./actions/aws-static-site`
  terraform.yml                       # EDIT: matrix over infra/envs/*, per-env init + OIDC role
infra/
  modules/aws/                        # MOVED from infra/modules/* (provider-namespaced)
    static_site/ acm_certificate/ github_oidc/
    static_site_stack/                # NEW bundle "recipe": zone lookup + cert + static_site
                                      #   + Route53 A/AAAA + github_oidc; manage_dns flag;
                                      #   configuration_aliases = [aws, aws.us_east_1]
  envs/                               # one dir per deployed site (concrete instances)
    _template/                        # NEW: copy-me skeleton (backend + provider + module call)
    bobs/{main.tf,versions.tf}        # NEW: migrates current root; keeps existing state key
    portfolio/{main.tf,versions.tf}   # NEW: apex (your account); reuses Bob's OIDC provider
    example-client/{main.tf,versions.tf} # NEW: foreign account+domain; validate-only
  README.md                           # NEW: provision/bootstrap + per-account onboarding guide
README.md                             # EDIT: reframe → reusable deploy catalog
```
Remove after migration: `infra/{main.tf,variables.tf,outputs.tf,versions.tf,terraform.tfvars.example}`.

## Multi-account & multi-domain model (core of the refactor)

All account/domain specifics live **in the env dir**, never in shared modules:
- **`versions.tf` per env** owns `backend "s3"` (bucket/key/region/lock — in that env's *own*
  account) + `provider "aws"` and alias `aws.us_east_1`. For your sites: your profile. For
  clients: that account's profile (bootstrap) — and CI provisioning uses OIDC into the terraform
  role, no profile needed.
- **`main.tf` per env** calls `module "site" { source = "../../modules/aws/static_site_stack" }`
  with `project_name`, `site_domain`, `hosted_zone_name`, `deploy_github_repo` (app repo for the
  deploy role), `mgmt_github_repo` (defaults to `derekadombek/website-deploy` for the terraform
  role), `github_branch`, `create_oidc_provider`, `manage_dns`, `tf_state_bucket`, `tf_lock_table`,
  and `providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }`.
- Module stays account-agnostic: uses handed-in providers, derives account id via
  `aws_caller_identity`, so IAM scoping is correct in any account.
- **OIDC provider:** `create_oidc_provider = true` in exactly one env per account.
- **`github_oidc` module change:** split the single `github_repo` into two trust targets — deploy
  role trusts the **app repo** (branch-scoped via `github_branch`), terraform role trusts the
  **management repo** scoped to a **GitHub Environment** (new `mgmt_environment` var, default
  `provisioning`) so its `sub` is `repo:<mgmt_repo>:environment:<env>`. Today both use one var.

## Phase 1 work items (the build)

1. **`actions/aws-static-site/action.yml`** — account-agnostic. Inputs (kebab): `aws-region`,
   `role-arn`, `s3-bucket`, `cloudfront-distribution-id`, `source-dir` (required);
   `build-command`, `install-command`, `node-version` (default `20`), `working-directory`
   (default `.`). `runs: using: composite`: setup-node (if build), install/build (if set), then
   the exact sync+invalidate logic from current `.github/workflows/deploy.yml`. Document caller
   needs `permissions: id-token: write`.
2. **Infra refactor** — `git mv infra/modules/* infra/modules/aws/`; new
   `infra/modules/aws/static_site_stack/` = current `infra/main.tf` logic as a module with
   `configuration_aliases`, `manage_dns` (false ⇒ skip cert/DNS, serve CloudFront default domain
   = "ship S3 only" recipe). Update `github_oidc` to take two trust targets (app repo / mgmt repo).
   Outputs: `s3_bucket`, `cloudfront_distribution_id`, `cloudfront_domain_name`, `site_url`,
   `deploy_role_arn`, `terraform_role_arn`.
3. **Per-site envs** —
   - `_template/` commented skeleton (backend + provider + full `module "site"` call).
   - `bobs/` keeps existing state key `website-deploy/terraform.tfstate`, your-account provider,
     `create_oidc_provider = true`, + Terraform `moved` blocks (`module.static_site`→
     `module.site.module.static_site`, `module.certificate`→…, `module.github_oidc`→…,
     `aws_route53_record.site_a/aaaa`→`module.site.aws_route53_record.*`) ⇒ **0 to destroy**.
   - `portfolio/` new key `sites/portfolio/terraform.tfstate`, `project_name="portfolio"`,
     `site_domain="derekadombek.com"`, `hosted_zone_name="derekadombek.com"`,
     `deploy_github_repo="derekadombek/portfolio"`, `create_oidc_provider = false`.
   - `example-client/` foreign account + client domain placeholder, `deploy_github_repo` = a
     client repo placeholder, `mgmt_github_repo` = `derekadombek/website-deploy`,
     `create_oidc_provider = true`; marked validate-only.
4. **`terraform.yml`** — `strategy.matrix` over envs; each leg `cd infra/envs/<site>`, init,
   fmt/validate, plan (PR comment); **apply job declares `environment: provisioning`** (required
   reviewers) and OIDC → that env's terraform role — the environment-scoped `sub` is what makes the
   token valid, so approval is enforced both by the gate and by the trust policy. Per-env role via
   `${{ vars[matrix.tf_role_var] }}`.
5. **Bob's `deploy.yml`** — replace inline logic with `uses: ./actions/aws-static-site`
   (`source-dir: site`, no build). Keeps Bob's working + dogfoods the action.
6. **Portfolio caller** — NEW `portfolio/.github/workflows/deploy.yml`: `on: push:[main] +
   workflow_dispatch`, `permissions:{id-token:write,contents:read}`, `concurrency`, one job:
   checkout → `uses: derekadombek/website-deploy/actions/aws-static-site@v1` with `vars.*` +
   `install-command: npm ci`, `build-command: npm run build`, `source-dir: dist`. Tag `v1`.
7. **Docs (user priority)** — `actions/README.md` (catalog + inputs + snippet + how to add an
   action); `infra/README.md` (env layout; **per-account onboarding guide** — one-time access →
   bootstrap apply → set repo Variables → OIDC-only thereafter; OIDC one-per-account; the two
   trust targets; "add a client" = copy `_template` + be admin on their repo); root `README.md`
   reframe; a `project` **memory** capturing architecture + gotchas.

## Phase 2 work items (DESIGNED, deferred — do not build yet)

Goal: reduce per-client onboarding toil. With the single OIDC model, the only privileged step is
the one-time bootstrap; everything after is OIDC-driven and already automatable.

- **One-time bootstrap** stays a documented manual `terraform apply` (needs the client's one-time
  admin/SSO access — OIDC can't exist yet). Optionally wrap as a `workflow_dispatch` that consumes
  client-provided temp creds.
- **`manage.yml` / extend `terraform.yml`** so post-bootstrap changes to any client env run from
  the `website-deploy` repo via OIDC into that account's terraform role — no creds, gated behind a
  GitHub **Environment** with required reviewers.
- **`gh variable set` automation** to push the 4 deploy Variables onto the (client-owned, you-admin)
  app repo from `terraform output`.
- **Sequencing rationale:** Phase 2 only wraps the Phase-1 manual path; prove the manual path
  first, then automate.

## Required GitHub repo Variables (Settings → Actions → Variables)
- **app repo (portfolio / client repo):** `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `S3_BUCKET`,
  `CLOUDFRONT_DISTRIBUTION_ID` (from `terraform output`).
- **website-deploy repo:** per-env `AWS_TF_ROLE_ARN_*` for CI provisioning, plus Bob's four deploy
  Variables (Bob's app repo == website-deploy).

## Risks / gotchas
- **Bob's state migration:** `terraform plan` must show **0 to destroy** before apply; `moved`
  blocks make re-parenting a no-op.
- **Apex collision:** confirm `derekadombek.com` apex isn't already pointed elsewhere.
- **OIDC provider is per-account:** exactly one env per account sets `create_oidc_provider=true`.
- **Bootstrap ordering:** first apply of any account is manual/privileged (one-time access); CI
  (OIDC) can only assume the terraform role once it exists.
- **Two trust targets:** deploy role → app repo OIDC; terraform role → `website-deploy` OIDC. Don't
  collapse them, or deploys and provisioning would share trust.

## Verification (user-run)
1. `cd infra/envs/bobs && terraform init && terraform plan` → **0 to destroy** (migration safe).
2. `cd infra/envs/portfolio && terraform init && terraform apply` → set portfolio Variables from
   outputs.
3. `terraform fmt -recursive -check` + per-env `terraform validate`.
4. `cd portfolio && npm ci && npm run build` → `dist/` produced.
5. Push to `portfolio` `main` (or `workflow_dispatch`) → action builds/syncs/invalidates →
   `https://derekadombek.com` live in under a minute.
6. Confirm Bob's still deploys via the refactored `./actions/aws-static-site`.
7. `cd infra/envs/example-client && terraform validate` → config-valid (proves the foreign-account
   env parses; not applied).
