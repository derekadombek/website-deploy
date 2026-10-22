# Client repo templates

Workflows to copy into a client's app repo (`.github/workflows/`).

| File | What it does |
|---|---|
| [`grant-access.yml`](grant-access.yml) | One-time: gives Derek's management repo keyless access to the client's AWS account. The client runs it with short-lived admin creds, then deletes those secrets and sends you their account id. |
| [`deploy.yml`](deploy.yml) | Every push: build (optional) → S3 → CloudFront. Fill in the client name + account id in the file; no repo Variables needed. |

A new account with no AWS access portal yet: set up IAM Identity Center first
([steps](../access-repo/README.md#short-lived-admin-keys-aws-access-portal)).

After it runs: add `clients/<name>.yaml` with that account id to the private
clients repo and merge,
then provision (see [`infra/README.md`](../../infra/README.md)).
