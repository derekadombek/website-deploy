# Clients

Real client files live in the private clients repo (`derekadombek/website-deploy-clients`),
not here: its workflows call this package's, and their run logs hold client details. This
folder keeps the field reference and [`example-client.yaml`](example-client.yaml). Locally,
point the scripts at the real ones with `CLIENTS_DIR=~/repos/website-deploy-clients/clients`.

One file per client: `clients/<name>.yaml`. **The filename is the client name** —
it's also the GitHub Environment name, the Terraform role trust
(`environment:<name>`), and the prefix for every resource (`<name>-site-<acct>`,
`<name>-terraform`, `<name>-tf-state`, …).

Adding a client = adding this file (the clients repo's **Add Client File** workflow
writes it from a form and opens the PR). Changing their domain = editing it.

The files can also live outside this repo: set `CLIENTS_DIR` to their folder and
the scripts (and Terraform, via `infra/scripts/tf.sh`) read them from there.

Keep it **flat `key: value`** (no nesting) — the scripts read it with plain shell.

```yaml
provider: aws                    # which infra/sites/<provider> root builds it
account_id: "123456789012"       # quoted — the client's AWS account
region: us-west-2
app_repo: acme-co/website        # repo that deploys the site (owner/name); not with site: false
domain: acme.com                 # "" = serve the CloudFront default URL for now
dns: existing-zone               # only when domain is set — see below
```

Optional (defaults shown):

```yaml
site: true                       # false = no website here (see "No site here")
hosted_zone: acme.com            # [= domain; site: false = <onsyte_subdomain>.<domain>]
                                 # Route 53 zone the records go in
www: true                        # serve www + 301 it to the apex
error_page: /index.html          # 404 page; /error.html for multi-page sites
app_branch: main                 # app repo branch allowed to deploy
ci: true                         # false = validate only; no GitHub Environment
delegate_from: acme              # domain is a subdomain of this client's zone —
                                 # Provision adds the NS record there (needs dns: external)
state_bucket: acme-tf-state      # [<name>-tf-state] Terraform state, in their account
state_lock: s3                   # [dynamodb] how state is locked — see below
lock_table: acme-tf-locks        # [<name>-tf-locks] only for state_lock dynamodb/both
onsyte_subdomain: onsyte         # [none] install Onsyte at onsyte.<domain> (needs domain;
                                 # needs grant-access from v1.3.0 or later; see "Onsyte
                                 # installs" below for the one-time steps)
onsyte_version: v0.1.0           # Onsyte release that Deploy Onsyte (clients repo) ships
```

`state_lock` — Terraform's DynamoDB locking is deprecated; the S3 lockfile
(`use_lockfile`) replaces it. **New clients: set `state_lock: s3`** and run
grant-access without `lock-table` (no table is created). The default is still
`dynamodb` so clients set up before the switch keep working.

Switching an existing client (each step is safe to stop after):

1. Re-run grant-access with this package version, still passing `lock-table`
   (gives the plan role access to the lockfile; it keeps the table access).
2. `state_lock: both` — every run takes both locks; run Provision (plan only).
3. Once no older checkout or run can still lock with only the table:
   `state_lock: s3`, re-run grant-access without `lock-table` (drops the table
   access), then delete the `<name>-tf-locks` table.

`dns` — where the domain's DNS lives:

| value | meaning |
|---|---|
| `existing-zone` | they already have a Route 53 hosted zone for it |
| `route53-registrar` | registered in Route 53 in their account — zone created + delegated automatically |
| `external` | zone created here; delegated automatically with `delegate_from`, otherwise you paste 4 nameservers at the registrar while Provision waits |

## No site here (`site: false`)

For a client whose website is hosted somewhere else and who only gets Onsyte in their
account. No S3 site, no CloudFront for it, no `app_repo`; the account gets a Route 53
zone for just `onsyte.<domain>`, and their own site and DNS stay where they are.

```yaml
provider: aws
account_id: "123456789012"
region: us-west-2
site: false
domain: acme.com                 # their domain; Onsyte goes at onsyte.acme.com
dns: external                    # zone onsyte.acme.com created here
state_lock: s3
onsyte_subdomain: onsyte
onsyte_version: v0.3.0
```

- **Access:** they run *Grant AWS access* from a small repo of their own made from
  [`templates/access-repo`](../templates/access-repo/) (no deploy role).
- **DNS:** Provision prints 4 nameservers and waits (up to 1h) while the client adds
  them as NS records for `onsyte` at their DNS provider. After Teardown they remove
  those records.
- `dns: existing-zone` also works, when their domain's zone is already in this
  account: set `hosted_zone` to it. `route53-registrar` doesn't apply.


## Onsyte installs: one-time steps

Two settings outside Terraform, done once per install. Deploy Onsyte checks the
first and warns about the second.

1. **Supabase sign-up off.** In the client's Supabase project, under Authentication,
   turn off *Allow new users to sign up*. Leave the **Email provider on** (turning
   it off blocks every sign-in). Onsyte creates accounts itself (first-run signup,
   invites), which works with sign-up off; with it on, anyone holding the public
   key in the page can create accounts. While there: minimum password length 10
   with letters and digits, and turn on leaked-password protection (Pro plan).
   Deploy Onsyte stops if sign-up is still on.
2. **SES production access.** A new AWS account can only email addresses verified
   in SES (the sandbox) until it asks once. Onsyte needs it for password-reset
   emails. From the client's account (their access-portal keys, like *Grant AWS
   access*), in the client's region, run:

   ```
   aws sesv2 put-account-details --region us-west-2 --production-access-enabled --mail-type TRANSACTIONAL --contact-language EN --website-url https://onsyte.acme.com --use-case-description "Password-reset emails from the company's own internal Onsyte tool to its staff. A few a month, only to people on the team; no marketing or bulk mail."
   ```

   AWS usually answers within a day. Until then Deploy Onsyte warns, and reset emails
   reach only addresses verified in SES.
