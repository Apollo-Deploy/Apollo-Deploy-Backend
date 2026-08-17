# Apollo Signal API

Internal service module for Signal. The `vps` root supplies its one primary AWS
region through `signal-aws`; the `local` root accepts development AWS inputs.
Both roots own the shared Docker services, migrations, OAuth records, and
secrets.
