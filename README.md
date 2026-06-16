# Static Site Deploy Pipeline (AWS + Terraform + GitHub Actions)

> **Case study:** turning a small business's "upload files by hand and hope" website
> into a one-command, reproducible, secure deployment pipeline.

This repo provisions the **entire hosting stack as code** and deploys a static
website automatically on every push — with HTTPS, a global CDN, a locked-down
origin, and zero long-lived cloud credentials.

The example site is **Bob's Fishing Tours**, a fictional small business, but the
setup is exactly what I'd stand up for a real client.

🔗 **Live demo:** https://bob.derekadombek.com  ·  Built for [derekadombek.com](https://derekadombek.com)

---

## The problem

A typical small business updates its website by dragging files into a hosting
control panel. That means:

- Manual, error-prone deploys with no rollback.
- No real HTTPS automation, or certs that quietly expire.
- A publicly readable storage bucket, or a server nobody patches.
- No way to reproduce the setup if the host disappears.

## What this builds

```
            git push (changes in site/)
                       │
                       ▼
            ┌─────────────────────┐
            │   GitHub Actions    │  assumes IAM role via OIDC
            │  (deploy.yml)       │  — no stored AWS keys
            └──────────┬──────────┘
                       │ aws s3 sync + invalidation
                       ▼
   ┌───────────┐   read-only    ┌──────────────────┐
   │ S3 bucket │◄──────(OAC)─────│   CloudFront     │◄── visitors (HTTPS)
   │ (private) │                 │  + ACM TLS cert  │
   └───────────┘                 └────────┬─────────┘
                                          │ alias record
                                          ▼
                                  ┌──────────────────┐
                                  │   Route 53 DNS    │  bob.derekadombek.com
                                  └──────────────────┘
```

**Everything above is defined in [`infra/`](infra/) as Terraform.** Standing up an
identical site for another business is a `terraform apply` with a different domain.

## What it demonstrates

| Practice | Where |
|---|---|
| Infrastructure as Code | [`infra/`](infra/) — composed from reusable modules |
| Reusable modules | [`infra/modules/`](infra/modules/) — `static_site`, `acm_certificate`, `github_oidc` |
| Private origin (no public bucket) | [`modules/static_site`](infra/modules/static_site/) + CloudFront **Origin Access Control** |
| Automated TLS | [`modules/acm_certificate`](infra/modules/acm_certificate/) — DNS-validated, auto-renewing |
| CI/CD | [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) |
| Keyless cloud auth | [`modules/github_oidc`](infra/modules/github_oidc/) — GitHub **OIDC**, least-privilege role |
| Cache strategy | long-cache assets, no-cache HTML, invalidate on deploy |
| Reproducibility | pinned providers (`.terraform.lock.hcl`), tagged resources |

---

## Repo layout

```
site/                       The static website (what gets deployed)
infra/                      Thin root that composes three modules:
  main.tf                     wires modules + DNS together
  modules/static_site/        private S3 + CloudFront (OAC) + bucket policy
  modules/acm_certificate/    ACM cert + DNS validation (us-east-1)
  modules/github_oidc/        OIDC provider + least-privilege deploy role
.github/workflows/          deploy.yml (publish) + terraform.yml (validate/plan)
```

Each module is self-contained with its own `variables`/`outputs`, so adding a
second site is a matter of calling `module "static_site"` again with a different
domain — the reason it's split this way.

## Prerequisites

- An AWS account, and a domain whose DNS is hosted in **Route 53**
  (the config looks up an existing hosted zone).
- Terraform ≥ 1.5 and the AWS CLI, configured with admin-ish creds for the
  first apply.

## One-time setup

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # edit domain, repo, etc.
terraform init
terraform apply
```

Terraform prints outputs including the **deploy role ARN**, **bucket name**, and
**CloudFront distribution ID**. Add these to the GitHub repo under
**Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` output |
| `AWS_REGION` | e.g. `us-east-1` |
| `S3_BUCKET` | `s3_bucket` output |
| `CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` output |

> Already have a GitHub OIDC provider in the account? Import it instead of
> letting Terraform create a duplicate:
> `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com`

## The everyday workflow

1. Edit anything in [`site/`](site/).
2. `git push` to `main`.
3. GitHub Actions assumes the AWS role via OIDC, syncs to S3, invalidates the
   CDN, and the change is live in well under a minute.

No console clicking, no FTP, no credentials on anyone's laptop.

## Cost

For a small-business-traffic static site this typically runs **a few dollars a
month or less** (S3 storage + CloudFront requests). `PriceClass_100` keeps the
CDN to North America + Europe to hold cost down.

## Teardown

```bash
cd infra
terraform destroy
```

---

## Outcome

Publishing a change goes from a nervous, manual, ~20-minute upload to a single
`git push` that is **live in under a minute — reproducible, reversible, and
secure by default**. The same pipeline drops onto any other small-business site
by changing a handful of variables.
