# Infra — provisioning catalog

Terraform that stands up the hosting stack for each client. Three layers:

```
clients/<name>.yaml          ONE FILE PER CLIENT — the only per-client input
                               (see clients/README.md for the fields)
infra/sites/aws/             one shared root that builds any AWS client:
                               reads clients/<name>.yaml, state in THEIR account
infra/modules/aws/           reusable building blocks (account-agnostic)
  static_site/                 private S3 + CloudFront (OAC) + bucket policy
  acm_certificate/             DNS-validated ACM cert (us-east-1)
  github_oidc/                 OIDC provider + deploy role + Terraform role
  static_site_stack/           BUNDLE: zone + cert + static_site + DNS
infra/access/                the trust foundation a client applies once
infra/scripts/tf.sh          run Terraform for one client: tf.sh <client> plan
```

The namespace is `sites/<provider>` + `modules/<provider>/<capability>`, and each
client file names its `provider:`, so GCP/Azure stay additive: a new
`infra/sites/gcp/` root + modules, and clients with `provider: gcp`. **All
account- and domain-specific values live in the client file; the roots and
modules never hardcode them.**

## Each client owns its own account boundary

`infra/sites/aws` has a partial `backend "s3" {}`. `tf.sh <client>` inits it
against that client's state — bucket `<name>-tf-state`, table `<name>-tf-locks`,
key `sites/<name>/terraform.tfstate`, all in **the client's own account** (override
with `state_bucket` / `lock_table`). Each client gets its own `.terraform-<name>`
data dir, so switching clients never reuses another client's backend. The
providers set `allowed_account_ids` from the client file, so Terraform refuses
to touch any other account.

```bash
infra/scripts/tf.sh portfolio plan     # local: uses your active AWS creds
infra/scripts/tf.sh portfolio output
```

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

### One model: access config + site

Every site — your own (e.g. `portfolio`) and clients alike — is onboarded the
same way. The **`aws-grant-access`** action runs once per account (with that
account's own creds) and stands up the trust foundation in the separate access
config (`infra/access`): the state backend + OIDC provider + deploy and
management roles, outputting the role ARNs. **No credentials are ever handed
over** — everything after is keyless over OIDC. The **site** (`infra/sites/aws`) then
builds only the website (S3 / CloudFront / DNS) and authenticates via that OIDC.

## Onboarding a client

Everything except step 1 is derived from the client name + account id, so there
are no ARNs to copy between steps.

1. **Client grants access (once, their account)** — they run `aws-grant-access`
   with their own admin creds, `project-name` + `mgmt-environment` = the client
   name, `state-bucket` `<name>-tf-state`, `lock-table` `<name>-tf-locks`, and
   their app repo. It creates the state backend + OIDC provider + deploy,
   Terraform and read-only plan roles. They send you their **AWS account id**.
2. **Add `clients/<name>.yaml`** (see [`clients/README.md`](../clients/README.md)) —
   PR, merge. Merging runs **Set CI Environment** automatically: it creates the
   client's GitHub Environment with `AWS_TF_ROLE_ARN` (built from the account id)
   + `AWS_REGION` + you as reviewer.
3. **Provision** — run **Provision Client's AWS Setup** from `main` (no inputs).
   It plans **every** client without asking (read-only), then waits for one
   approval covering every client whose plan has changes — read the plans in
   the run summary, then in *Review deployments* tick them all and approve. It
   handles every DNS case from the client file — see *DNS* below. For an outside
   registrar it prints 4 nameservers in the run summary and waits while you
   paste them.
4. **Wire the app repo** — Variables `AWS_REGION`,
   `AWS_DEPLOY_ROLE_ARN` (`arn:aws:iam::<acct>:role/<name>-github-deploy`),
   `S3_BUCKET` + `CLOUDFRONT_DISTRIBUTION_ID` (`tf.sh <name> output`), and the
   deploy workflow from the [top-level README](../README.md). Push → live.

Your **own** sites follow the same flow.

**Adding a domain later** — edit the client file (`domain`, `dns`), merge, and
re-run step 3. It's an additive in-place change (CloudFront gets the alias + ACM
cert; content untouched).

**Offboarding** is clean: the client deletes the access config (OIDC provider +
two roles + state) and revokes your admin on their app repo, and you're fully out
— nothing was ever stored on your side. To just stop billing, run **Teardown
Client's AWS Setup** (destroys the site, keeps the access config).

### DNS: client already on Route 53, or not yet

Setting `domain` needs a Route 53 hosted zone for it. Pick `dns` in the client file:

- **Client already uses Route 53** → `dns: existing-zone`. The module looks up the
  existing zone.
- **Client has no Route 53 zone yet** → the module creates the zone. Then delegation has to happen before ACM can validate, and how
  that's handled depends on where the domain is registered:
  - **Registered in Route 53 / Amazon Registrar (this account)** →
    `dns: route53-registrar`. The nameservers are set automatically — fully
    hands-off, a single `terraform apply` works.
  - **Subdomain of another client's zone** (e.g. `bob.derekadombek.com` under
    portfolio's `derekadombek.com`) → `dns: external` + `delegate_from: portfolio`.
    Provision writes the NS record into the parent zone itself — fully
    hands-off — and Teardown removes it. Needs the parent's
    `<parent>-dns-delegation` role (below).
  - **Registered elsewhere (GoDaddy, Namecheap, …)** → `dns: external`. Provision
    creates the zone, prints the nameservers, **waits for you/the client to paste
    them at the registrar**, then finishes the apply so it never hangs at cert
    validation. Locally, the babysitter script does the same:
    ```bash
    AWS_PROFILE=<client-bootstrap> infra/scripts/onboard-site.sh <client>
    ```
    (Re-runnable — if you bail during the wait, run it again and it resumes.)

> **Re-run guardrail.** With intact Terraform state, re-running bootstrap or
> onboard is a safe no-op (the backend creator skips existing resources; apply is
> declarative). The danger is a re-run that can't see its state (deleted/renamed
> state bucket, wrong backend) — Terraform would recreate everything and silently
> make a **duplicate Route 53 zone**. So when state is empty, `onboard-site.sh`
> (and Provision) **check the account** for the client's site bucket, CloudFront
> distribution and (if it creates one) DNS zone. Nothing there = genuine first run,
> go ahead; anything there = **refuse**, listing what it found. No flag to set.

### Delegation role (for `delegate_from`)

The parent client's account needs a `<parent>-dns-delegation` role, created by
its access stack when given a zone — re-run the access step with
`--delegation-zone`:

```bash
AWS_PROFILE=derek infra/scripts/grant-access.sh --project portfolio --region us-west-2 \
  --deploy-repo derekadombek/portfolio --mgmt-environment portfolio \
  --state-bucket website-deploy-tf-state-west --lock-table website-deploy-tf-locks \
  --delegation-zone derekadombek.com
```

It trusts any GitHub Environment job in this repo (all have required reviewers)
and can **only** create/delete NS records for subdomains in that one zone — never
the apex. Always pass `--delegation-zone` when re-running portfolio's access
step, or the role is removed.

For a client keeping DNS elsewhere entirely (Cloudflare, etc.), leave `domain: ""`
(ship the CloudFront default domain) and have them CNAME to it.

## GitHub Environments (this repo)

CI management is per **GitHub Environment**, one per client, named the same as
the client. Each holds:

- **scoped variables** `AWS_TF_ROLE_ARN` + `AWS_REGION`,
- its own **required reviewers** (the approval that mints the env-scoped OIDC token).

Three roles per client account, three trust targets — never collapse them:

| Role | Trusts | Can |
|---|---|---|
| `<name>-github-deploy` | the client's app repo, `main` | sync the site + invalidate |
| `<name>-plan` | this repo, `main` (no approval) | **read** the site + state, take the lock |
| `<name>-terraform` | this repo, environment `<name>` (approval) | change the site |

**Set CI Environment** keeps them in sync with `clients/`: it runs on every merge
that touches `clients/` (or by hand, no inputs) and creates/updates an environment
for each client. Clients with `ci: false` (e.g. `example-client`) get none, so
they're validated but never planned/applied. It never deletes an environment —
remove one by hand after removing a client. Provision always covers every
client; Teardown and Unlock take one client name and reject anything without a
`clients/<name>.yaml`. All three share one concurrency group, so only one
Terraform run happens at a time, across all branches.

## Terraform version

Everything runs **one** Terraform version, pinned in `.terraform-version` (and the
workflows' `TERRAFORM_VERSION`, which CI checks matches). State written by a newer
Terraform can't be read by an older one, so match it locally:

```bash
brew uninstall terraform; brew install tfenv && tfenv install && tfenv use
```

(`tfenv` reads `.terraform-version`.) The `aws-grant-access` action pins the same
version — move the `v1` tag after changing it so client repos pick it up.

## Stale state lock

A cancelled or crashed run can leave its lock behind ("Error acquiring the state
lock"). When **no run for that client is still going**, run **Unlock Client State**
with the client and the lock ID from the error — it runs on the client's own role,
so you need no credentials for their account.

## Verify

```bash
terraform fmt -recursive -check
# Credential-free check of a client file + the shared root:
bash -c 'source infra/scripts/lib/client.sh && client_tf_init example-client -backend=false && terraform validate'
```
