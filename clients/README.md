# Clients

Real client files live in the private clients repo (`derekadombek/website-deploy-clients`),
not here: its workflows call this package's, and their run logs hold client details. This
folder keeps the field reference and [`example-client.yaml`](example-client.yaml). Locally,
point the scripts at the real ones with `CLIENTS_DIR=~/repos/website-deploy-clients/clients`.

One file per client: `clients/<name>.yaml`. **The filename is the client name** —
it's also the GitHub Environment name, the Terraform role trust
(`environment:<name>`), and the prefix for every resource (`<name>-site-<acct>`,
`<name>-terraform`, `<name>-tf-state`, …).

Adding a client = adding this file. Changing their domain = editing it.

The files can also live outside this repo: set `CLIENTS_DIR` to their folder and
the scripts (and Terraform, via `infra/scripts/tf.sh`) read them from there.

Keep it **flat `key: value`** (no nesting) — the scripts read it with plain shell.

```yaml
provider: aws                    # which infra/sites/<provider> root builds it
account_id: "123456789012"       # quoted — the client's AWS account
region: us-west-2
app_repo: acme-co/website        # repo that deploys the site (owner/name)
domain: acme.com                 # "" = serve the CloudFront default URL for now
dns: existing-zone               # only when domain is set — see below
```

Optional (defaults shown):

```yaml
hosted_zone: acme.com            # [= domain] Route 53 zone the domain lives in
www: true                        # serve www + 301 it to the apex
error_page: /index.html          # 404 page; /error.html for multi-page sites
app_branch: main                 # app repo branch allowed to deploy
ci: true                         # false = validate only; no GitHub Environment
delegate_from: acme              # domain is a subdomain of this client's zone —
                                 # Provision adds the NS record there (needs dns: external)
state_bucket: acme-tf-state      # [<name>-tf-state] Terraform state, in their account
lock_table: acme-tf-locks        # [<name>-tf-locks]
```

`dns` — where the domain's DNS lives:

| value | meaning |
|---|---|
| `existing-zone` | they already have a Route 53 hosted zone for it |
| `route53-registrar` | registered in Route 53 in their account — zone created + delegated automatically |
| `external` | zone created here; delegated automatically with `delegate_from`, otherwise you paste 4 nameservers at the registrar while Provision waits |
