# Access repo template

For a client with **no site here**: they only get an app (e.g. Onsyte) in their AWS
account, and their website is hosted somewhere else. They have no app repo, so they
make a small private repo of their own just to run this once.

| File | What it does |
|---|---|
| [`grant-access.yml`](grant-access.yml) | One-time: gives Derek's management repo keyless access to the client's AWS account. Same as the client-repo version, minus the deploy role (nothing deploys from here). The client runs it with short-lived admin creds, then deletes those secrets and sends you their account id. |

The repo isn't used again after that: nothing in the account trusts it.

## Short-lived admin keys (AWS access portal)

The workflow needs temporary admin keys from the AWS access portal, which comes with
IAM Identity Center (free). A new account doesn't have it yet. Once, signed in to the
AWS console as the account's owner:

1. Open **IAM Identity Center** → **Enable**. Keep the recommended option (with AWS
   Organizations): it makes an organization with this account as its management
   account. Nothing else changes.
2. **Users** → **Add user**: yourself, with your email. Accept the invite email and set
   a password (and MFA).
3. **Permission sets** → **Create permission set** → predefined
   **AdministratorAccess**.
4. **AWS accounts** → tick this account → **Assign users or groups** → your user →
   **AdministratorAccess**.
5. Open the **AWS access portal URL** (on the Identity Center dashboard), sign in →
   the account → **Access keys**: the three values for the repo secrets.

The keys expire on their own (1 hour by default). Keep the portal for later: it's how
you sign in to the account from now on, instead of the root user.

After it runs: add `clients/<name>.yaml` with `site: false` and that account id to the
private clients repo and merge, then provision (see
[`clients/README.md`](../../clients/README.md), "No site here").
