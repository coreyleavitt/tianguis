## Tracer bullet: prove the toolchain wires together end-to-end.
## An empty Index serializes to KDL and parses back to itself.

import std/unittest
import tianguis/[model, kdl_io]

suite "tracer":
  test "empty index round-trips through KDL":
    let original = Index(schemaVersion: 1, packages: @[])
    let serialized = formatKdl(original)
    let parsed = parseKdl(serialized)
    check parsed.isOk
    check parsed.get == original
