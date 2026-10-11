# website-deploy — a reusable, multi-account static-site deploy catalog

A toolkit for hosting static sites on AWS as code: a catalog of reusable
**Terraform modules** and **GitHub composite actions** that any app repo can call
to provision hosting and deploy on every push — with HTTPS, a global CDN, a
locked-down origin, and **zero long-lived cloud credentials**.

It runs **multi-account** (each client lives in its own AWS account) and
**multi-domain** (each site has its own domain + hosted zone). Authentication is
GitHub OIDC federated directly into each account — nothing is stored anywhere.

🔗 First dogfood target: **[derekadombek.com](https://derekadombek.com)** (the portfolio site).

---

## Two halves of the catalog

| | What | Where |
|---|---|---|
| **Deploy** | composite action: optional build → `s3 sync` → CloudFront invalidate, keyless via OIDC | [`actions/`](actions/) |
| **Provision** | Terraform modules + one shared root per cloud, driven by a small file per client | [`infra/`](infra/), [`clients/`](clients/) |

A caller repo stays thin — it checks out and calls the action:

```yaml
permissions: { id-token: write, contents: read }
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
          install-command: npm ci      # omit for a no-build site
          build-command: npm run build  # omit for a no-build site
          source-dir: dist
```

The four `vars.*` come from `terraform output` after provisioning the site.

## How it deploys (no stored keys)

```
            git push (app repo)
                   │
                   ▼
        ┌─────────────────────┐   assumes the deploy role via OIDC
        │   GitHub Actions    │   — short-lived creds, nothing stored
        │  aws-static-site    │
        └──────────┬──────────┘
                   │ (optional build) → s3 sync → invalidate
                   ▼
   ┌───────────┐  read-only   ┌──────────────────┐
   │ S3 bucket │◄────(OAC)─────│   CloudFront     │◄── visitors (HTTPS)
   │ (private) │               │  + ACM TLS cert  │
   └───────────┘               └────────┬─────────┘
                                        │ alias record
                                        ▼
                                ┌──────────────────┐
                                │   Route 53 DNS    │  <site domain>
                                └──────────────────┘
```

GitHub OIDC federates **directly into the target account** — there is no central
ops account, no `assume_role` chain, no stored credentials. Each account holds a
low-privilege **deploy role** (app repo, branch-scoped, runs on push) and a broad
**Terraform role** (this repo, scoped to a GitHub Environment with required
reviewers, so it's inert without a human approval). Full model + onboarding guide:
[`infra/README.md`](infra/README.md).

## Repo layout

```
actions/                       reusable composite actions  (→ actions/README.md)
  aws-static-site/               build → s3 sync → CloudFront invalidate
clients/                        one <name>.yaml per client  (→ clients/README.md)
infra/                          provisioning catalog        (→ infra/README.md)
  sites/aws/                     shared root: builds any AWS client from its file
  modules/aws/                   static_site · acm_certificate · github_oidc
                                 · static_site_stack (the bundle recipe)
  access/                        trust foundation a client applies once
.github/workflows/
  provision-client-aws.yml       per-client plan/apply, gated by its approval
  (+ set-ci-environment / provision-client-external-domain / teardown)
```

## Onboarding a site (short version)

1. The client runs `aws-grant-access` once in their account (their creds) and
   sends you their account id. Everything after is keyless OIDC.
2. Add `clients/<name>.yaml` and merge (that sets up its CI environment), then
   run **Provision Client's AWS Setup** for `<name>` and approve.
3. Set the app repo's four `vars.*` and add the deploy workflow (snippet above).
   Push → live in under a minute.

Full walkthrough, the auth model, and "add a client": [`infra/README.md`](infra/README.md).
Action inputs + more examples: [`actions/README.md`](actions/README.md).

## What it demonstrates

| Practice | Where |
|---|---|
| Reusable IaC modules | [`infra/modules/aws/`](infra/modules/aws/) |
| Cross-repo composite action | [`actions/aws-static-site/`](actions/aws-static-site/) |
| Multi-account / multi-domain isolation | [`clients/`](clients/) + [`infra/sites/aws/`](infra/sites/aws/) — per-client state, account guard, trust |
| Private origin (no public bucket) | `static_site` + CloudFront Origin Access Control |
| Automated TLS | `acm_certificate` — DNS-validated, auto-renewing |
| Keyless cloud auth + human-gated provisioning | `github_oidc` — two trust targets, env-gated Terraform role |
| Cache strategy | long-cache assets, no-cache HTML, invalidate on deploy |

## Cost

A small-business static site typically runs **a few dollars a month or less**
(S3 + CloudFront). `PriceClass_100` keeps the CDN to North America + Europe.
