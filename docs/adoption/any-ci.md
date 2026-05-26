# Publishing to tianguis from any CI

If your repo lives somewhere other than GitHub, you don't get the
[reusable workflow convenience](github.md) — but the underlying protocol
is just a four-step shell pipeline. Any CI provider whose OIDC issuer is
[trusted by Sigstore Fulcio](https://github.com/sigstore/fulcio/blob/main/federation/README.md)
can publish.

**Confirmed working** (Sigstore-federated as of 2026-05-26):

- GitLab CI
- Codeberg / Forgejo / Woodpecker CI
- Buildkite
- Google Cloud Build
- CircleCI

**Not currently supported**: sourcehut builds (sourcehut's OIDC issuer
is not in Sigstore's federation, so cosign keyless cannot mint a
signing certificate from a sourcehut workflow). This is a sourcehut
upstream limitation; revisit if federation expands.

## The protocol (four steps)

```
1. Pack source tree into a deterministic tar.gz
2. Push as OCI artifact to any OCI v2 registry, capture the digest
3. Cosign keyless-sign the OCI ref (uses CI's OIDC)
4. POST to https://dispatch.tianguis.dev/v1/publish with the OCI ref
   and the OIDC bearer token
```

Authors who use `milpa publish` get all four steps as one command. If
you'd rather call the steps directly, here's what each does.

## Example: GitLab CI

```yaml
publish:
  stage: deploy
  rules:
    - if: $CI_COMMIT_TAG =~ /^v/
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  image: python:3.12-slim
  before_script:
    - apt-get update && apt-get install -y curl git
    - pip install git+https://github.com/coreyleavitt/milpa.git@main
    - curl -sL https://github.com/oras-project/oras/releases/download/v1.2.0/oras_1.2.0_linux_amd64.tar.gz | tar -xz -C /usr/local/bin oras
    - curl -sL https://github.com/sigstore/cosign/releases/download/v2.4.0/cosign-linux-amd64 -o /usr/local/bin/cosign && chmod +x /usr/local/bin/cosign
  script:
    - oras login registry.gitlab.com -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD"
    - |
      milpa publish \
        --name=my-package \
        --version="$CI_COMMIT_TAG" \
        --registry="registry.gitlab.com/$CI_PROJECT_PATH:$CI_COMMIT_TAG" \
        --provider=gitlab \
        --repo-url="$CI_PROJECT_URL" \
        --signed-by="$CI_PROJECT_URL/.gitlab-ci.yml@$CI_COMMIT_REF_NAME" \
        --oidc-token-env=SIGSTORE_ID_TOKEN
```

Adapt the `image:`, `before_script:`, and registry login lines to your
specific CI. The core invocation (`milpa publish ...`) is identical
across providers.

## Manual / scripted publishes

If you prefer not to use `milpa publish` (e.g. you're writing a custom
publish flow), here's the four steps as raw shell. This is essentially
what `milpa publish` does internally.

```bash
#!/usr/bin/env bash
set -euo pipefail

NAME="my-package"
VERSION="v1.0.0"
REGISTRY_REF="ghcr.io/me/my-package:$VERSION"
PROVIDER="github"     # or "gitlab", "codeberg", etc.
REPO_URL="https://github.com/me/my-package"
SIGNED_BY="$REPO_URL/.github/workflows/publish.yaml@refs/tags/$VERSION"

# Step 1: pack (deterministic — mtime=0, sorted entries, excludes .git)
tar --sort=name --mtime='1970-01-01' --owner=0 --group=0 --numeric-owner \
    --exclude-vcs -czf /tmp/source.tar.gz .

# Step 2: push the OCI artifact, capture the digest
oras push "$REGISTRY_REF" \
    "/tmp/source.tar.gz:application/vnd.tianguis.source.v1.tar+gzip" \
    | tee /tmp/oras.out
DIGEST=$(grep -oE 'sha256:[0-9a-f]+' /tmp/oras.out | head -1)
OCI_REF="ghcr.io/me/my-package@$DIGEST"

# Step 3: cosign keyless-sign the artifact (Rekor entry created automatically)
cosign sign --yes "$OCI_REF"

# Step 4: POST to dispatch with the CI's OIDC bearer
#   $OIDC_TOKEN must contain a Sigstore-trusted JWT (see your CI's docs
#   for how to request one with audience "sigstore")
curl -fsS -X POST https://dispatch.tianguis.dev/v1/publish \
    -H "Authorization: Bearer $OIDC_TOKEN" \
    -H "Content-Type: application/json" \
    --data @- <<EOF
{
  "name": "$NAME",
  "version": "$VERSION",
  "oci_ref": "$OCI_REF",
  "provider": "$PROVIDER",
  "repo_url": "$REPO_URL",
  "signed_by": "$SIGNED_BY"
}
EOF
```

Note: the raw `tar` invocation above is *approximately* deterministic.
`milpa publish` is more careful (zero uid/gid/uname, mode normalisation,
gzip mtime=0) — if you want byte-stable artifacts that recompute to the
same content_hash milpa would later derive, use `milpa publish`.

## What `signed_by` should be

`signed_by` is the cosign keyless identity that signed the OCI artifact.
For workflow-driven publishes, this is the workflow file URL plus the
ref the workflow ran against:

| Platform | Shape |
|---|---|
| GitHub Actions | `https://github.com/<owner>/<repo>/.github/workflows/<file>@refs/tags/<tag>` |
| GitLab CI | `<project_url>/.gitlab-ci.yml@<ref>` |
| Codeberg/Forgejo | `<repo_url>/.forgejo/workflows/<file>@<ref>` |

The dispatch endpoint cross-checks this against the OIDC token's
`repository` / `project_path` claim. Mismatches return `403
identity_mismatch`.

## What if my CI's OIDC issuer isn't federated?

You can't use cosign keyless. Options:

- Run the publish from a federated CI instead (e.g. a GitHub Actions
  job triggered by your primary CI). The OCI artifact + signature
  live wherever; only the publish workflow needs to be on a federated
  platform.
- Wait for your CI's issuer to be added to Sigstore's federation. Most
  serious CI products are gradually being added; check
  [Fulcio's federation list](https://github.com/sigstore/fulcio/tree/main/federation).

We do not support long-lived signing keys as an alternative to cosign
keyless. That trust model is materially weaker than the
ephemeral-workload-identity model Sigstore is designed for.
