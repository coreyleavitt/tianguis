## JSON projection round-trip tests.
##
## The JSON form is the cross-ecosystem interop projection of the
## index. Bijection with the data model is the load-bearing property:
## parse(format(idx)) == idx.

import std/[unittest, options, strutils, tables]
import tianguis/[model, json_io]

suite "json roundtrip":
  test "empty index round-trips through JSON":
    let original = Index(schemaVersion: 1, packages: @[])
    let serialized = formatJson(original)
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original

  test "version requires map round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"results": "^0.5.0", "stew": "^0.1.0"}.toOrderedTable,
        )],
      )],
    )
    let parsed = parseJson(formatJson(original))
    check parsed.isOk
    check parsed.get == original

  test "version with git + oci provenances round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos", namespace: "ns",
          upstream: "https://x/chronos",
          versions: @[Version(
            version: "0.5.0", contentHash: "sha256:abc",
            attestation: "author-signed", signedBy: "https://x/me",
            publishedAt: "2026-05-25T00:00:00Z",
            provenances: @[
              Provenance(kind: pkGit, url: "https://x/c.git",
                         gitRef: "v0.5.0", commitSha: "abc123"),
              Provenance(kind: pkOci, registry: "ghcr.io",
                         repository: "x/c", digest: "sha256:def"),
            ],
          )],
        ),
      ],
    )
    let parsed = parseJson(formatJson(original))
    check parsed.isOk
    check parsed.get == original

  test "one-package one-version round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
          versions: @[
            Version(
              version: "0.5.0",
              contentHash: "sha256:abc",
              attestation: "milpa-vendored",
              signedBy: "milpa-bot",
              publishedAt: "2026-05-25T00:00:00Z",
            ),
          ],
        ),
      ],
    )
    let serialized = formatJson(original)
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original

  test "rekor pointer round-trips through JSON (author-signed)":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "author-signed",
          signedBy: "https://github.com/coreyleavitt",
          publishedAt: "2026-06-08T01:18:24Z",
          rekor: some(RekorRef(
            uuid: "108e9186e8c5677a", logIndex: "1753541583",
            integratedTime: "1780881469",
          )),
        )],
      )],
    )
    let serialized = formatJson(original)
    check "rekor" in serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original

  test "rekor=none emits no rekor key in JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendored", namespace: "ns", upstream: "https://x/v",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          rekor: none(RekorRef),
        )],
      )],
    )
    let serialized = formatJson(original)
    check "rekor" notin serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].rekor.isNone

  test "bundle pin (sha256) round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "nkdl", namespace: "github.com/coreyleavitt",
        upstream: "https://github.com/coreyleavitt/nkdl",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:dd907474",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-08T01:18:24Z",
          bundlePin: some("ab".repeat(32)),
        )],
      )],
    )
    let serialized = formatJson(original)
    check "bundle_pin" in serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.packages[0].versions[0].bundlePin.get == "ab".repeat(32)

  test "bundle pin absent emits no bundle_pin key in JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendored", namespace: "ns", upstream: "https://x/v",
        versions: @[Version(
          version: "0.1.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-06-06T00:00:00Z",
          bundlePin: none(string),
        )],
      )],
    )
    let serialized = formatJson(original)
    check "bundle_pin" notin serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].bundlePin.isNone

  test "attestation-epoch round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      attestationEpoch: some("2026-07-01T00:00:00Z"),
      packages: @[],
    )
    let serialized = formatJson(original)
    check "attestation_epoch" in serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original
    check parsed.get.attestationEpoch.get == "2026-07-01T00:00:00Z"

  test "attestation-epoch absent emits no attestation_epoch key in JSON":
    let original = Index(
      schemaVersion: 1,
      attestationEpoch: none(string),
      packages: @[],
    )
    let serialized = formatJson(original)
    check "attestation_epoch" notin serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get.attestationEpoch.isNone

  # ---------------------------------------------------------------------------
  # Package-level authorized_signer (rfc-attestation-delivery S8 Layer 3 —
  # per-package signer-continuity ratchet, tianguis#42)
  # ---------------------------------------------------------------------------

  test "authorized_signer round-trips through JSON when set":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "libp2p", namespace: "github.com/alice",
        upstream: "https://github.com/alice/libp2p",
        authorizedSigner: some(
          "https://github.com/alice/libp2p/.github/workflows/publish.yaml@refs/heads/main"),
      )],
    )
    let serialized = formatJson(original)
    check "authorized_signer" in serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original

  test "authorized_signer absent emits no authorized_signer key in JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "vendoredonly", namespace: "ns",
        upstream: "https://x/vendoredonly",
        authorizedSigner: none(string),
      )],
    )
    let serialized = formatJson(original)
    check "authorized_signer" notin serialized
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get.packages[0].authorizedSigner.isNone

  test "one-package zero-versions round-trips through JSON":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://github.com/coreyleavitt/chronos",
        ),
      ],
    )
    let serialized = formatJson(original)
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original
