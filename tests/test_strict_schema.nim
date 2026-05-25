## Strict-schema enforcement tests for both projections.
##
## Unknown nodes / properties / missing required fields produce typed
## errors carrying a stable IDX-* code consumers can rely on (the
## bijection discipline carried over from milpa's error catalog).

import std/unittest
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

suite "json strict schema":
  test "unknown top-level key rejected with IDX-NODE-UNKNOWN":
    let parsed = parseJson("""{"schema_version":1,"packages":[],"bogus":42}""")
    check parsed.isErr
    check parsed.getErr.code == iecUnknownNode

  test "valid empty index parses without error":
    let parsed = parseJson("""{"schema_version":1,"packages":[]}""")
    check parsed.isOk
