# Architecture & design decisions

A short tour of *why* the stack is built this way.

## Request flow

A visitor hits the site (e.g. `https://derekadombek.com`):

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
- **Two trust targets, one human gate.** The deploy role trusts the app repo
  (branch-scoped) and runs on every push. The broad Terraform role trusts *this*
  management repo scoped to a GitHub Environment with required reviewers, so it is
  inert until a human approves — even though it stands permanently.
- **Per-account isolation.** GitHub OIDC federates directly into each account; there
  is no central ops account or `assume_role` chain. Each site's state, providers, and
  trust live in its own `infra/envs/<site>` dir, so accounts never share anything.
- **Cache strategy.** Fingerprint-free static assets are sent with a long
  `immutable` cache, HTML is sent `no-cache`, and every deploy issues a CloudFront
  invalidation so updates are visible immediately without sacrificing CDN speed.

## Trade-offs / next steps

- **Remote state, per account.** Each `infra/envs/<site>` keeps its own S3 +
  DynamoDB backend in its own account — no shared state bucket. The one-time
  bootstrap creates it (see [`../infra/README.md`](../infra/README.md)).
- **CI is fully wired.** `provision-client-aws.yml` is dispatched manually per env
  (validate → plan → apply) behind that env's GitHub Environment approval;
  `teardown-client-aws.yml` destroys, and `provision-client-external-domain.yml`
  handles external-registrar DNS delegation.
- **Phase 2 (deferred):** automate per-client onboarding — wrap the one-time
  bootstrap and push the four deploy Variables from `terraform output` via `gh`.
- A natural follow-on demo: add automated backups and uptime monitoring on top of
  this same site (the other planned case studies).
