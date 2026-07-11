## Strict-schema enforcement tests for both projections.
##
## Unknown nodes / properties / missing required fields produce typed
## errors carrying a stable IDX-* code consumers can rely on (the
## bijection discipline carried over from milpa's error catalog).

import std/[unittest, options, strutils]
import tianguis/[model, kdl_io, json_io]

suite "kdl strict schema":
  test "unknown top-level node rejected with IDX-NODE-UNKNOWN":
    let parsed = parseKdl("schema_version 1\nbogus \"x\"\n")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "unknown child node in package rejected with IDX-NODE-UNKNOWN":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    bogus "y"
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "unknown child node in version rejected with IDX-NODE-UNKNOWN":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    version "0.1.0" {
        content_hash "sha256:a"
        bogus "y"
        attestation "milpa-vendored"
        signed_by "x"
        published_at "2026-01-01T00:00:00Z"
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "unknown child node in rekor block rejected with IDX-NODE-UNKNOWN":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    version "0.1.0" {
        content_hash "sha256:a"
        attestation "author-signed"
        signed_by "https://github.com/x"
        published_at "2026-01-01T00:00:00Z"
        rekor {
            uuid "abc"
            bogus "y"
        }
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "bundle node with malformed sha256 (non-64-hex) rejected with IDX-TYPE-MISMATCH":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    version "0.1.0" {
        content_hash "sha256:a"
        attestation "milpa-vendored"
        signed_by "milpa-bot"
        published_at "2026-01-01T00:00:00Z"
        bundle sha256="not-hex"
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecBadType

  test "bundle node missing sha256 property rejected with IDX-TYPE-MISMATCH":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    version "0.1.0" {
        content_hash "sha256:a"
        attestation "milpa-vendored"
        signed_by "milpa-bot"
        published_at "2026-01-01T00:00:00Z"
        bundle
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecBadType

  test "bundle node with valid 64-hex sha256 parses without error":
    let src = """
schema_version 1
package "x" {
    namespace "ns"
    upstream "https://x"
    version "0.1.0" {
        content_hash "sha256:a"
        attestation "milpa-vendored"
        signed_by "milpa-bot"
        published_at "2026-01-01T00:00:00Z"
        bundle sha256="ab00000000000000000000000000000000000000000000000000000000000000"
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].bundlePin.isSome

  test "valid index with rekor block parses without error":
    let src = """
schema_version 1
package "nkdl" {
    namespace "github.com/coreyleavitt"
    upstream (url)"https://github.com/coreyleavitt/nkdl"
    version "0.1.0" {
        content_hash "sha256:dd"
        attestation "author-signed"
        signed_by "https://github.com/coreyleavitt"
        published_at "2026-06-08T01:18:24Z"
        rekor {
            uuid "108e9186"
            log_index "1753541583"
            integrated_time "1780881469"
        }
    }
}
"""
    let parsed = parseKdl(src)
    check parsed.isOk
    check parsed.get.packages[0].versions[0].rekor.isSome

  test "valid index parses without error":
    let src = """
schema_version 1
package "chronos" {
    namespace "coreyleavitt"
    upstream (url)"https://example.com/chronos"
}
"""
    let parsed = parseKdl(src)
    check parsed.isOk

  test "root attestation-epoch node is accepted (not rejected as unknown)":
    let src = """
schema_version 1
attestation-epoch "2026-07-01T00:00:00Z"
package "chronos" {
    namespace "coreyleavitt"
    upstream (url)"https://example.com/chronos"
}
"""
    let parsed = parseKdl(src)
    check parsed.isOk
    check parsed.get.attestationEpoch.isSome
    check parsed.get.attestationEpoch.get == "2026-07-01T00:00:00Z"

  test "a genuinely unknown root node is still rejected with IDX-NODE-UNKNOWN":
    let src = """
schema_version 1
attestation-epoch "2026-07-01T00:00:00Z"
totally-bogus-root-node "x"
package "chronos" {
    namespace "coreyleavitt"
    upstream (url)"https://example.com/chronos"
}
"""
    let parsed = parseKdl(src)
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

suite "json strict schema":
  test "unknown top-level key rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""{"schema_version":1,"packages":[],"bogus":42}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "valid empty index parses without error":
    let parsed = parseJson("""{"schema_version":1,"packages":[]}""")
    check parsed.isOk

  # #16 — nested strict-schema parity with KDL: unknown keys inside package,
  # version, provenance, and rekor objects are rejected (not silently ignored).

  test "unknown key inside package object rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""
      {"schema_version":1,"packages":[
        {"name":"x","namespace":"ns","upstream":"https://x","bogus":1}
      ]}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode
    check "bogus" in parsed.getErr.message
    check "packages[0]" in parsed.getErr.message

  test "unknown key inside version object rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""
      {"schema_version":1,"packages":[
        {"name":"x","namespace":"ns","upstream":"https://x","versions":[
          {"version":"0.1.0","content_hash":"sha256:a","bogus":true}
        ]}
      ]}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode
    check "packages[0].versions[0]" in parsed.getErr.message

  test "unknown key inside provenance object rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""
      {"schema_version":1,"packages":[
        {"name":"x","namespace":"ns","upstream":"https://x","versions":[
          {"version":"0.1.0","content_hash":"sha256:a","provenances":[
            {"kind":"git","url":"https://x","bogus":"y"}
          ]}
        ]}
      ]}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode
    check "provenances[0]" in parsed.getErr.message

  test "unknown key inside rekor object rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""
      {"schema_version":1,"packages":[
        {"name":"x","namespace":"ns","upstream":"https://x","versions":[
          {"version":"0.1.0","content_hash":"sha256:a",
           "rekor":{"uuid":"abc","bogus":"y"}}
        ]}
      ]}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode
    check ".rekor" in parsed.getErr.message

  test "valid fully-nested index (with rekor) parses without error":
    let parsed = parseJson("""
      {"schema_version":1,"packages":[
        {"name":"nkdl","namespace":"github.com/coreyleavitt",
         "upstream":"https://github.com/coreyleavitt/nkdl","versions":[
          {"version":"0.1.0","content_hash":"sha256:dd",
           "requires":{"chronos":"^0.5.0"},
           "provenances":[{"kind":"oci","registry":"ghcr.io",
             "repository":"coreyleavitt/nkdl","digest":"sha256:01"}],
           "attestation":"author-signed","signed_by":"https://github.com/coreyleavitt",
           "published_at":"2026-06-08T01:18:24Z",
           "rekor":{"uuid":"108e9186","log_index":"1753541583",
             "integrated_time":"1780881469"}}
        ]}
      ]}""")
    check parsed.isOk
