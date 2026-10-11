# Client repo templates

Workflows to copy into a client's app repo (`.github/workflows/`).

| File | What it does |
|---|---|
| [`grant-access.yml`](grant-access.yml) | One-time: gives website-deploy keyless access to the client's AWS account. The client runs it with short-lived admin creds, then deletes those secrets and sends you their account id. |

After it runs: add `clients/<name>.yaml` here with that account id and merge,
then provision (see [`infra/README.md`](../../infra/README.md)).
