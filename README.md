# prova-rs package-registry

The plugin discovery index for [Prova](https://github.com/prova-rs/prova). **A registry is a git
repository containing one TOML file per plugin** — no server, no API, no database. Every installed
`prova` binary knows this repo as its built-in default registry:

```bash
prova plugins                    # list everything
prova plugins postgres           # search (name, description, capabilities)
prova plugins info postgres      # one entry, full detail
prova plugins add postgres       # pin into your prova.toml — then require("postgres")
```

Discovery-only, by design: `require` never resolves through a registry. `add` writes an ordinary
pinned `[plugins]` entry into your manifest; from that moment the registry is out of the picture
and a fresh checkout reproduces your run with zero registries configured.

## Entries

One file per plugin under [`registry/`](registry/). Each entry is a **projection of the plugin's
own manifest** — derived by [`scripts/derive_entry.py`](scripts/derive_entry.py) from the
`[plugin]` section, never hand-maintained metadata that can drift:

```toml
schema       = 1
name         = "postgres"
repo         = "https://github.com/prova-rs/prova-postgres"
description  = "PostgreSQL — docker-exec over psql, zero native code"
capabilities = ["postgres"]
latest       = "v1.0"        # the recommended pin `add` writes when no @ref is given
```

`name`, `repo`, and `description` are required; readers ignore unknown keys, and entries carrying
a newer `schema` major are skipped per-entry — old binary, newer registry: degraded, never broken.

## Registration is automation, not curation

Three paths in, one path out:

- **Reconcile (zero-touch, credential-free).** [`reconcile.yml`](.github/workflows/reconcile.yml)
  runs every 6 hours and converges the registry onto the org's state: any `prova-rs/prova-*` repo
  with a release and a `[plugin]` manifest gets an entry at its latest release; entries whose
  repos are deleted or archived are removed. Create a plugin, cut a release, and it appears —
  delete the repo and it disappears.
- **Register dispatch (low-latency, explicit).** `register.yml` takes `{ repo, ref }`, derives
  the entry from the plugin checkout, and upserts it. A plugin's release workflow can trigger it
  for instant registration (needs a token with `actions: write` on this repo — see below):

  ```yaml
  # .github/workflows/register.yml in a plugin repo
  name: register
  on:
    release:
      types: [published]
  jobs:
    register:
      runs-on: ubuntu-latest
      steps:
        - env:
            GH_TOKEN: ${{ secrets.PROVA_DISPATCH_TOKEN }}
          run: |
            gh workflow run register.yml -R prova-rs/package-registry \
              -f repo="${{ github.repository }}" -f ref="${{ github.event.release.tag_name }}"
  ```

  `PROVA_DISPATCH_TOKEN` is the org-wide secret prova's release automation already uses for
  cross-repo work — every plugin repo inherits it. If the dispatch ever fails, the reconcile
  loop still registers the release within 6 hours.
- **Pull request (the third-party path).** Anyone can PR an entry file; review of that one-file
  diff is the curation step. The proof suite validates it like every other entry.

`remove.yml` is the explicit delete verb (`{ name }`); reconcile also removes automatically.

## The registry proves itself

[`proofs/registry_test.lua`](proofs/registry_test.lua) is a Prova suite asserting every entry is
served warning-free by the real consumer (`prova plugins` pointed at this checkout), names match
filenames, schemas are known, and repos are well-formed. It gates PRs and runs after every
automation commit.

```bash
prova            # run it locally (needs the prova binary on PATH)
```

## Listing another registry

Registries are org-granularity trust. To add your own alongside this one:

```toml
# ~/.config/prova/config.toml
[[registries]]
name   = "acme"
source = "https://github.com/acme/prova-registry"
```
