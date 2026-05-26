# Publishing a Nim package to tianguis from GitHub

If your repo lives on GitHub Actions, adoption is one file. Drop the
following into `.github/workflows/publish.yaml` in your repo:

```yaml
name: publish

on:
  push:
    tags: ["v*"]

jobs:
  publish:
    uses: coreyleavitt/tianguis/.github/workflows/publish.yaml@v1
    with:
      name: my-package           # must match your milpa.kdl
      version: ${{ github.ref_name }}
    permissions:
      id-token: write   # cosign keyless signing
      contents: read    # checkout
      packages: write   # push the OCI artifact to GHCR
```

Push a tag (`git tag v1.0.0 && git push origin v1.0.0`) and within
~60 seconds the new version appears in the tianguis index.

## What it does

For every tag push that matches `v*`, the reusable workflow:

1. Packs your source tree into a byte-deterministic tar.gz
   (excludes `.git/` to match milpa's identity algorithm)
2. Pushes it as an OCI artifact to `ghcr.io/<owner>/<repo>:<tag>`
3. Cosign keyless-signs the artifact using your workflow's GH Actions
   OIDC identity (signature lands in Rekor automatically)
4. POSTs to `https://dispatch.tianguis.dev/v1/publish` with the OCI ref
   and your signer identity

The tianguis commit workflow then `cosign verify`s your signature,
recomputes the content hash, and commits the entry to `index.kdl`
under attestation `author-signed`.

## Required secret (temporary)

While milpa is still private, you must pass a fine-grained PAT with
read access to `coreyleavitt/milpa`:

```yaml
    uses: coreyleavitt/tianguis/.github/workflows/publish.yaml@v1
    secrets:
      milpa-install-token: ${{ secrets.MILPA_READ_PAT }}
```

Once milpa is published to PyPI / made public, this secret goes away.

## Optional inputs

| Input | Default | Purpose |
|---|---|---|
| `registry` | `ghcr.io/<owner>/<repo>:<version>` | Publish to a registry other than GHCR (Docker Hub, Quay, lscr.io, Harbor — anything OCI v2) |
| `dispatch-url` | `https://dispatch.tianguis.dev` | Override for staging / self-hosted |
| `dry-run` | `false` | Pack + push + sign without the dispatch POST. Lets you verify the OCI artifact + Rekor entry before going live. |

## Smoke-testing your setup

To verify the workflow works without actually publishing, run it once
with `dry-run: true`:

```yaml
jobs:
  publish:
    uses: coreyleavitt/tianguis/.github/workflows/publish.yaml@v1
    with:
      name: my-package
      version: v0.0.0-test
      dry-run: true
    permissions: { id-token: write, contents: read, packages: write }
```

The artifact lands in GHCR and the cosign signature lands in Rekor,
but tianguis doesn't commit anything to its index. Inspect the OCI
ref + Rekor entry to confirm everything looks right, then remove
`dry-run: true` for real publishes.

## Troubleshooting

**`dispatch rejected publish (403 identity_mismatch)`** — your workflow's
`signed_by` identity URL doesn't match the `repo_url` the dispatch
endpoint expects. This usually means your reusable-workflow invocation
references a fork or a non-default branch. The `signed_by` is computed
from `github.workflow_ref`, which must point at your repo.

**`oras push failed: unauthorized`** — your job doesn't have
`packages: write`. Add it to the `permissions:` block.

**`cosign sign failed: no OIDC token in env`** — your job doesn't have
`id-token: write`. Add it.

## Versioning

This reusable workflow is pinned at `@v1`. Breaking changes will land
as `@v2` with a migration note in the release. Pin to `@v1` (not
`@main`) so unrelated tianguis changes don't break your publishing.
