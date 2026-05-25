## Conformance test for tianguis's content-hash identity algorithm.
##
## Bit-identical agreement with milpa's `compute_content_hash` is the
## load-bearing property for the multi-impl claim. Any divergence
## means index entries written by tianguis can't be verified by
## milpa (or vice versa).
##
## Fixtures in tests/fixtures/identity_conformance.json are generated
## by running milpa's algorithm against known input trees; this test
## materializes each input under tmp, runs tianguis's port, and
## asserts the hash matches.

import std/[unittest, json, os, tempfiles]
import tianguis/identity

const FIXTURES_PATH = currentSourcePath().parentDir() / "fixtures" / "identity_conformance.json"

proc materializeTree(root: string, fixture: JsonNode) =
  for f in fixture["files"]:
    let p = root / f["relpath"].getStr
    createDir(p.parentDir)
    writeFile(p, f["content"].getStr)
    if f["executable"].getBool:
      var perms = getFilePermissions(p)
      perms = perms + {fpUserExec, fpGroupExec, fpOthersExec}
      setFilePermissions(p, perms)
  for l in fixture["links"]:
    let p = root / l["relpath"].getStr
    createDir(p.parentDir)
    createSymlink(l["target"].getStr, p)

suite "identity conformance vs milpa":
  let corpus = parseFile(FIXTURES_PATH)

  for fixture in corpus["fixtures"]:
    let name = fixture["name"].getStr
    test "fixture: " & name:
      let tmp = createTempDir("tianguis-id-", "")
      try:
        materializeTree(tmp, fixture)
        let actual = computeContentHash(tmp)
        let expected = fixture["expected_identity"].getStr
        check actual == expected
      finally:
        removeDir(tmp)
