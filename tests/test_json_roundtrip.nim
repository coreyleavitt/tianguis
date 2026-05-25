## JSON projection round-trip tests.
##
## The JSON form is the cross-ecosystem interop projection of the
## index. Bijection with the data model is the load-bearing property:
## parse(format(idx)) == idx.

import std/[unittest, tables]
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
