# Publishing a Nim package to tianguis from GitHub

If your repo lives on GitHub Actions, adoption is one workflow file. Drop
the following into `.github/workflows/publish.yaml` in your repo:

```yaml
name: publish

on:
  push:
    tags: ["v*"]

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # cosign keyless signing + this action's own
                        # attestation signing + the dispatch bearer token
      contents: read    # checkout
      packages: write   # push the OCI artifact to GHCR
    steps:
      - uses: actions/checkout@v6

      - uses: coreyleavitt/tianguis/.github/actions/publish@main
        with:
          name: my-package           # must match your milpa.kdl
          version: ${{ github.ref_name }}
```

Push a tag (`git tag v1.0.0 && git push origin v1.0.0`) and within
~60 seconds the new version appears in the tianguis index.

**Important:** the action must run as a step in **your own job**, via
`uses:` under `steps:` — never call it as a reusable workflow (`uses:
.../publish.yaml` under `jobs:`). Reusable workflows run as their own
job, which stamps the cosign signature and the attestation with a
SHARED identity instead of your repo's own — see "Why a composite
action" below.

## What it does

For every tag push that matches `v*`, the `.github/actions/publish`
composite action:

1. Installs `milpa` + builds the `tianguis` CLI
2. Runs `milpa publish`, which packs your git HEAD's source tree into a
   byte-deterministic tar.gz, pushes it as an OCI artifact to
   `ghcr.io/<owner>/<repo>:<version>` (or your `target` override),
   cosign keyless-signs it under your workflow's own GH Actions OIDC
   identity, and verifies the pushed digest before signing
3. Mints a per-entry §1 attestation binding the published content hash
   to your signer identity, signed the same way
4. POSTs the publish request (name, version, OCI ref, signer identity,
   attestation bundle) to `https://dispatch.tianguis.dev/v1/publish`

The tianguis commit workflow then `cosign verify`s your signature,
recomputes the content hash, verifies the attestation bundle, and
commits the entry to `index.kdl` under attestation `author-signed`.

## Why a composite action, not a reusable workflow

A **composite action** (`uses: .../actions/publish@ref` inside your
own job's `steps:`) runs *inside* your job — so the ambient OIDC
token GitHub hands to `cosign sign` (and to this action's own
attestation signing) carries **your repo's own** `job_workflow_ref`,
and the Fulcio certificate's SAN reflects your real per-repo identity.

A **reusable workflow** (`uses: .../publish.yaml` under `jobs:`) runs
as its *own* job instead, so GitHub stamps the OIDC token with the
*reusable workflow's own* path — every author publishing through it
would sign under the exact same shared identity, making a compromised
or malicious author indistinguishable from tianguis's own
infrastructure. tianguis's now-retired `.github/workflows/publish.yaml`
had this problem; it fails fast with a migration notice if anything
still references it.

## Required secret (temporary)

While milpa is still private, you must pass a fine-grained PAT with
read access to `coreyleavitt/milpa`:

```yaml
      - uses: coreyleavitt/tianguis/.github/actions/publish@main
        with:
          name: my-package
          version: ${{ github.ref_name }}
          milpa-git-read-pat: ${{ secrets.MILPA_GIT_READ_PAT }}
```

Once milpa is published to PyPI / made public, this input goes away.

## Optional inputs

| Input | Default | Purpose |
|---|---|---|
| `target` | `ghcr.io/<owner>/<repo>` | Push to a registry/repository other than GHCR (Docker Hub, Quay, lscr.io, Harbor — anything OCI v2). No `:tag` suffix — milpa appends `:<version>` itself. |
| `dispatch-url` | `https://dispatch.tianguis.dev` | Override for staging / self-hosted |
| `dry-run` | `false` | Still really packs + pushes + signs the OCI artifact (so you can inspect it and its Rekor entry), but the dispatch POST carries `dry_run: true`, which makes the dispatch endpoint skip triggering the index commit. |
| `milpa-ref` | (pinned commit) | Override the pinned `milpa` commit the action installs from (advanced; must stay in lockstep with tianguis's own server-side pin) |

## Smoke-testing your setup

To verify the pipeline works without landing an index entry, run once
with `dry-run: true`:

```yaml
      - uses: coreyleavitt/tianguis/.github/actions/publish@main
        with:
          name: my-package
          version: v0.0.0-test
          dry-run: true
```

The artifact still lands in GHCR and the cosign signature still lands
in Rekor (there is no way to validate the signing/push path without
actually pushing), but tianguis's dispatch endpoint won't commit
anything to its index. Inspect the OCI ref + Rekor entry to confirm
everything looks right, then remove `dry-run: true` for real publishes.

## Making the GHCR package public

A newly created GHCR package defaults to **private** visibility. After
your first publish, go to your package's settings on GitHub
(`https://github.com/users/<you>/packages/container/<repo>/settings`
or the org equivalent) and set it to **Public** — otherwise milpa's
unauthenticated `oras pull` on the consumer side (anyone installing
your package via tianguis) will fail to fetch it.

## Troubleshooting

**`dispatch rejected publish (403 identity_mismatch)`** — the OIDC
token's repo claim doesn't match the repo the dispatch endpoint
expects. This usually means the action isn't running as a step in your
own job (see "Why a composite action, not a reusable workflow" above).

**`oras push failed: unauthorized`** — your job doesn't have
`packages: write`. Add it to the `permissions:` block.

**`cosign sign failed: no OIDC token in env`** — your job doesn't have
`id-token: write`. Add it.

**`milpa publish` fails with `PUBLISH-VERSION-TAG-MISMATCH`** — your
`version` input doesn't match a tag (`<version>` or `v<version>`)
pointing at the checked-out commit. Make sure you checked out the tag
itself (the default `actions/checkout@v6` behavior on a `push: tags:`
trigger already does this).

## Versioning

Pin the action to `@main` for now (pre-1.0; no `@v1` yet). A future
stable tag will get a migration note in the release when it lands.
