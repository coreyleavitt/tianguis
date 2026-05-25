## JSON projection round-trip tests.
##
## The JSON form is the cross-ecosystem interop projection of the
## index. Bijection with the data model is the load-bearing property:
## parse(format(idx)) == idx.

import std/unittest
import tianguis/[model, json_io]

suite "json roundtrip":
  test "empty index round-trips through JSON":
    let original = Index(schemaVersion: 1, packages: @[])
    let serialized = formatJson(original)
    let parsed = parseJson(serialized)
    check parsed.isOk
    check parsed.get == original
