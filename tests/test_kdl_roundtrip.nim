## KDL projection round-trip tests beyond the empty-index tracer.
##
## Each test asserts: serialize an Index value to KDL, parse it back,
## get the same Index. Bijection through canonical KDL is the load-
## bearing property for spec conformance.

import std/[unittest, sequtils, strutils, tables]
import tianguis/[model, kdl_io]

suite "kdl roundtrip":
  test "one-package zero-versions round-trips through KDL":
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
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original

  test "packages emerge alphabetical regardless of input":
    proc pkg(name: string): Package =
      Package(name: name, namespace: "ns", upstream: "https://x/" & name)
    let original = Index(
      schemaVersion: 1,
      packages: @[pkg("zoo"), pkg("alpha"), pkg("middle")],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let names = canonicalized.get.packages.mapIt(it.name)
    check names == @["alpha", "middle", "zoo"]

  test "versions emerge in descending semver order regardless of input":
    let original = Index(
      schemaVersion: 1,
      packages: @[
        Package(
          name: "chronos",
          namespace: "coreyleavitt",
          upstream: "https://example.com/chronos",
          versions: @[
            Version(version: "0.4.0", contentHash: "sha256:a",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-01-01T00:00:00Z"),
            Version(version: "0.5.0", contentHash: "sha256:b",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-02-01T00:00:00Z"),
            Version(version: "0.4.5", contentHash: "sha256:c",
                    attestation: "milpa-vendored", signedBy: "b",
                    publishedAt: "2026-03-01T00:00:00Z"),
          ],
        ),
      ],
    )
    let canonicalized = parseKdl(formatKdl(original))
    check canonicalized.isOk
    let vs = canonicalized.get.packages[0].versions
    check vs.len == 3
    check vs[0].version == "0.5.0"
    check vs[1].version == "0.4.5"
    check vs[2].version == "0.4.0"

  test "version requires map round-trips through KDL (canonical input)":
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
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  test "version requires keys emit alphabetically regardless of input order":
    let backward = Index(
      schemaVersion: 1,
      packages: @[Package(
        name: "chronos", namespace: "ns", upstream: "https://x/c",
        versions: @[Version(
          version: "0.5.0", contentHash: "sha256:abc",
          attestation: "milpa-vendored", signedBy: "milpa-bot",
          publishedAt: "2026-05-25T00:00:00Z",
          requires: {"stew": "^0.1.0", "results": "^0.5.0"}.toOrderedTable,
        )],
      )],
    )
    let serialized = formatKdl(backward)
    let resultsIdx = serialized.find("\"results\"")
    let stewIdx = serialized.find("\"stew\"")
    check resultsIdx < stewIdx

  test "version with git + oci provenances round-trips through KDL":
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
              attestation: "author-signed",
              signedBy: "https://github.com/coreyleavitt",
              publishedAt: "2026-05-25T00:00:00Z",
              provenances: @[
                Provenance(
                  kind: pkGit,
                  url: "https://github.com/coreyleavitt/chronos.git",
                  gitRef: "v0.5.0",
                  commitSha: "abcdef1234567890",
                ),
                Provenance(
                  kind: pkOci,
                  registry: "ghcr.io",
                  repository: "coreyleavitt/chronos",
                  digest: "sha256:fedcba",
                ),
              ],
            ),
          ],
        ),
      ],
    )
    let parsed = parseKdl(formatKdl(original))
    check parsed.isOk
    check parsed.get == original

  test "one-package one-version round-trips through KDL":
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
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
