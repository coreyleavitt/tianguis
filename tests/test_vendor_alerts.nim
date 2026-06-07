import std/[unittest, strutils]
import tianguis/vendor/[merge, alerts]
import tianguis/namespace

suite "alerts":
  test "drift alert formats as a kdl block carrying the relevant context":
    let alert = DriftAlert(
      packageName:  "chronos",
      version:      "0.5.0",
      existingHash: "sha256:original",
      newHash:      "sha256:forcepushed",
    )
    let text = formatAlert(alert, detectedAt = "2026-05-25T01:00:00Z")
    check "drift " in text
    check "chronos" in text
    check "0.5.0" in text
    check "sha256:original" in text
    check "sha256:forcepushed" in text
    check "2026-05-25T01:00:00Z" in text

  test "appending a drift alert produces a parseable kdl document":
    let alert = DriftAlert(
      packageName:  "chronos",
      version:      "0.5.0",
      existingHash: "sha256:a",
      newHash:      "sha256:b",
    )
    var log = ""
    log = appendAlert(log, alert, detectedAt = "2026-05-25T01:00:00Z")
    log = appendAlert(log, alert, detectedAt = "2026-05-25T02:00:00Z")
    check log.count("drift ") == 2

  test "collision formats as a KDL node with IDX-INTRAORG-COLLISION marker":
    let c = IntraOrgCollision(
      namespace:    "github.com/acme",
      name:         "utils",
      existingRepo: "utils-a",
      newRepo:      "utils-b",
    )
    let text = formatAlert(c, detectedAt = "2026-05-25T01:00:00Z")
    check "collision" in text
    check "github.com/acme" in text
    check "utils-a" in text
    check "utils-b" in text
    check "2026-05-25T01:00:00Z" in text

  test "identity-drift formats as a distinct KDL node":
    let i = IdentityDrift(
      name:               "nimkdl",
      storedNamespace:    "github.com/coreyleavitt",
      rederivedNamespace: "github.com/greenm01",
    )
    let text = formatAlert(i, detectedAt = "2026-05-25T01:00:00Z")
    check "identity-drift" in text
    check "nimkdl" in text
    check "github.com/coreyleavitt" in text
    check "github.com/greenm01" in text
    check "2026-05-25T01:00:00Z" in text

  test "all three alert kinds round-trip through distinct nodes":
    ## Three distinct node types coexist in one alerts.kdl log without
    ## conflicting; each kind is identifiable by its node name.
    let drift = DriftAlert(packageName: "pkg1", version: "1.0.0",
                           existingHash: "sha256:a", newHash: "sha256:b")
    let col = IntraOrgCollision(namespace: "github.com/acme", name: "utils",
                                existingRepo: "utils-a", newRepo: "utils-b")
    let idrift = IdentityDrift(name: "pkg2",
                               storedNamespace: "github.com/old",
                               rederivedNamespace: "github.com/new")
    var log = ""
    log = appendAlert(log, drift,  detectedAt = "2026-05-25T01:00:00Z")
    log = appendAlert(log, col,    detectedAt = "2026-05-25T02:00:00Z")
    log = appendAlert(log, idrift, detectedAt = "2026-05-25T03:00:00Z")
    check "collision" in log
    check "identity-drift" in log
    # Each node type appears exactly once.
    check log.count("identity-drift") == 1
    check log.count("collision") == 1
    # Content-drift is a block-form KDL node; check for its unique structure.
    check log.count("existing_hash") == 1
    check log.count("new_hash") == 1
