## KDL projection round-trip tests beyond the empty-index tracer.
##
## Each test asserts: serialize an Index value to KDL, parse it back,
## get the same Index. Bijection through canonical KDL is the load-
## bearing property for spec conformance.

import std/unittest
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
