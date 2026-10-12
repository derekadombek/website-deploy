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
   their app repo. It creates the state backend + OIDC provider + deploy and
   Terraform roles. They send you their **AWS account id**.
2. **Add `clients/<name>.yaml`** (see [`clients/README.md`](../clients/README.md)) —
   PR, merge. Merging runs **Set CI Environment** automatically: it creates the
   client's GitHub Environment with `AWS_TF_ROLE_ARN` (built from the account id)
   + `AWS_REGION` + you as reviewer.
3. **Provision** — **Provision Client's AWS Setup**, client `<name>`
   (`confirm_fresh` on the first run), approve. It handles every DNS case from
   the client file — see *DNS* below. For an outside registrar it prints 4
   nameservers in the run summary and waits while you paste them.
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
    # first-ever provision needs CONFIRM_FRESH=1 (guardrail below)
    CONFIRM_FRESH=1 AWS_PROFILE=<client-bootstrap> infra/scripts/onboard-site.sh <client>
    ```
    (Re-runnable — if you bail during the wait, run it again and it resumes.)

> **Re-run guardrail.** With intact Terraform state, re-running bootstrap or
> onboard is a safe no-op (the backend creator skips existing resources; apply is
> declarative). The danger is a re-run that can't see its state (deleted/renamed
> state bucket, wrong backend) — Terraform would recreate everything and silently
> make a **duplicate Route 53 zone**. So `onboard-site.sh` (and Provision)
> **refuse to apply against empty state** unless `CONFIRM_FRESH=1` /
> `confirm_fresh`, which you set only for the genuine first run.

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

**Set CI Environment** keeps them in sync with `clients/`: it runs on every merge
that touches `clients/` (or by hand, no inputs) and creates/updates an environment
for each client. Clients with `ci: false` (e.g. `example-client`) get none, so
they're validated but never planned/applied. It never deletes an environment —
remove one by hand after removing a client. The provision
and teardown workflows take the client name as free text (no default) and
reject anything without a `clients/<name>.yaml`.

## Verify

```bash
terraform fmt -recursive -check
# Credential-free check of a client file + the shared root:
bash -c 'source infra/scripts/lib/client.sh && client_tf_init example-client -backend=false && terraform validate'
```
