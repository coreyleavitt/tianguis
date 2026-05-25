## CLI tests for `tianguis project [--check]`.
##
## Tests invoke cmdProject directly rather than spawning the binary —
## the proc takes a project directory and returns an exit code, so
## the dispatch logic is testable without subprocess overhead.

import std/[unittest, os, strutils, tempfiles]
import tianguis/cli

template withTempProject(name: untyped, body: untyped) =
  let name {.inject.} = createTempDir("tianguis-test-", "")
  try:
    body
  finally:
    removeDir(name)

suite "cli project":
  test "project --check passes when index.kdl and index.json agree":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      writeFile(tmp / "index.json",
                """{"schema_version":1,"packages":[]}""")
      check cmdProject(tmp, check = true) == 0

  test "project --check fails when index.json drifts from index.kdl":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      writeFile(tmp / "index.json",
                """{"schema_version":42,"packages":[]}""")
      check cmdProject(tmp, check = true) != 0

  test "project (no --check) regenerates index.json from index.kdl":
    withTempProject(tmp):
      writeFile(tmp / "index.kdl", "schema_version 1\n")
      # Pre-existing stale JSON gets overwritten.
      writeFile(tmp / "index.json",
                """{"schema_version":42,"packages":[]}""")
      check cmdProject(tmp, check = false) == 0
      let regenerated = readFile(tmp / "index.json")
      check """"schema_version":1""" in regenerated
      check """"schema_version":42""" notin regenerated

  test "project --check fails with non-zero when index.kdl is missing":
    withTempProject(tmp):
      # No index.kdl — error path.
      check cmdProject(tmp, check = true) != 0
