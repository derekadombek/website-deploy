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
          client-name: acme             # = clients/acme.yaml
          aws-account-id: "123456789012"
          install-command: npm ci      # omit for a no-build site
          build-command: npm run build  # omit for a no-build site
          source-dir: dist
```

The action works out the deploy role, bucket and CloudFront distribution from the
client name + account id — no repo Variables. Full template:
[`templates/client-repo/deploy.yml`](templates/client-repo/deploy.yml).

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
**Terraform role** (the private clients repo, scoped to that client's GitHub
Environment; Provision only plans unless you tick *apply*). Full model + onboarding guide:
[`infra/README.md`](infra/README.md).

## Repo layout

```
actions/                       reusable composite actions  (→ actions/README.md)
  aws-static-site/               build → s3 sync → CloudFront invalidate
clients/                        field reference + example   (→ clients/README.md;
                                 real files: private clients repo)
infra/                          provisioning catalog        (→ infra/README.md)
  sites/aws/                     shared root: builds any AWS client from its file
  modules/aws/                   static_site · acm_certificate · github_oidc
                                 · static_site_stack (the bundle recipe)
  access/                        trust foundation a client applies once
.github/workflows/              reusable (workflow_call); the clients repo calls them
  provision-client-aws.yml       per-client plan/apply
  (+ set-ci-environment / teardown / unlock-client-state)
```

## Onboarding a site (short version)

1. The client runs `aws-grant-access` once in their account (their creds) and
   sends you their account id. Everything after is keyless OIDC.
2. Add `clients/<name>.yaml` in the private clients repo and merge (that sets up
   its CI environment), then run **Provision Client's AWS Setup** there (it plans
   every client).
3. Add the deploy workflow (snippet above) with their name + account id.
   Push → live in under a minute.

Full walkthrough, the auth model, and "add a client": [`infra/README.md`](infra/README.md).
Action inputs + more examples: [`actions/README.md`](actions/README.md).

## Releases and upgrades

Releases are `vX.Y.Z` tags with notes in [`CHANGELOG.md`](CHANGELOG.md), including
**upgrade notes** for anything a caller has to do. Pushing the tag runs
[`release.yml`](.github/workflows/release.yml): it creates the GitHub Release and
moves `v1` to it.

Callers pin an **exact version** and never `@v1`. That means the clients repo's
workflows (`uses: …@v1.2.0` plus `package_ref: v1.2.0`) and each client repo's
`deploy.yml` / `grant-access.yml`. An upgrade is a PR that bumps the pin.
[Renovate](https://docs.renovatebot.com/) opens it when a release ships, with this
`renovate.json` in each calling repo (the custom manager keeps `package_ref` in step
with `uses:`):

```json
{
  "extends": ["config:recommended"],
  "packageRules": [
    { "matchDepNames": ["derekadombek/website-deploy"], "groupName": "website-deploy" }
  ],
  "customManagers": [
    {
      "customType": "regex",
      "managerFilePatterns": ["/^\\.github/workflows/.+\\.ya?ml$/"],
      "matchStrings": ["package_ref:\\s*(?<currentValue>v\\d+\\.\\d+\\.\\d+)"],
      "depNameTemplate": "derekadombek/website-deploy",
      "datasourceTemplate": "github-tags"
    }
  ]
}
```

Rolling out an upgrade in the clients repo:

1. Read the release's upgrade notes. Merge the pin-bump PR.
2. Run **Provision** (plan only) and read each client's plan.
3. Run it again with **apply** ticked. Every applied client ends with a **health
   check** (its domain answers over HTTPS). If that fails, revert the bump PR and apply
   again to roll back. Terraform state is versioned in S3 if the rollback needs it.
4. Client repos: merge their pin-bump PR. The next push deploys with it.

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
