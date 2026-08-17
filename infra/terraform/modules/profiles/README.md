# API service modules

These are internal Docker service modules used by the two supported roots:
`terraform/local` and `terraform/vps`.

- `platform-api` runs Platform, nginx, and Certbot.
- `signal-api` runs Signal on the shared network with its explicit AWS inputs.
- `billing-api` runs Billing on Platform's shared network, database, Redis, and
  OAuth issuer.

They take already-created connections and secrets. They do not create databases,
OAuth records, DNS, or credentials, and they are not published to a private
Terraform registry. Use the local source paths already composed by the roots.
