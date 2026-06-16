# Architecture & design decisions

A short tour of *why* the stack is built this way.

## Request flow

A visitor hits `https://bob.derekadombek.com`:

1. **Route 53** resolves the domain to the CloudFront distribution (alias record).
2. **CloudFront** terminates TLS using the **ACM** certificate and serves cached
   content from the nearest edge location.
3. On a cache miss, CloudFront reads from the **private S3 bucket** using its
   **Origin Access Control** (OAC) identity — the bucket itself is not public.

## Why these choices

- **Private S3 + CloudFront OAC, not a public S3 website.** A public bucket is the
  most common way these setups leak. OAC means only CloudFront can read objects;
  there is no public bucket endpoint to find.
- **ACM with DNS validation.** Certificates auto-renew with no human in the loop and
  no cron job to forget. The cert lives in `us-east-1` because CloudFront requires it.
- **OIDC instead of access keys.** GitHub Actions exchanges a short-lived OIDC token
  for temporary AWS credentials. There are no `AWS_ACCESS_KEY_ID`/`SECRET` values
  stored in the repo to leak or rotate.
- **Least-privilege deploy role.** The CI role can only write to *this* bucket and
  invalidate *this* distribution — nothing else in the account.
- **Cache strategy.** Fingerprint-free static assets are sent with a long
  `immutable` cache, HTML is sent `no-cache`, and every deploy issues a CloudFront
  invalidation so updates are visible immediately without sacrificing CDN speed.

## Trade-offs / next steps

- **State is local by default** so the demo runs with zero prerequisites. For team
  use, switch on the S3 + DynamoDB backend stubbed in `infra/versions.tf`.
- **`terraform plan` in CI is stubbed but disabled** until the OIDC role + remote
  state exist; the workflow runs `fmt`/`validate` unconditionally.
- A natural follow-on demo: add automated backups and uptime monitoring on top of
  this same site (the other planned case studies).
