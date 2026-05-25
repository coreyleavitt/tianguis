import std/[unittest, strutils]
import tianguis/vendor/[merge, alerts]

suite "alerts":
  test "drift alert formats as a kdl block carrying the relevant context":
    let alert = DriftAlert(
      packageName:  "chronos",
      version:      "0.5.0",
      existingHash: "sha256:original",
      newHash:      "sha256:forcepushed",
    )
    let text = formatDriftAlert(alert, detectedAt = "2026-05-25T01:00:00Z")
    check "drift " in text
    check "chronos" in text
    check "0.5.0" in text
    check "sha256:original" in text
    check "sha256:forcepushed" in text
    check "2026-05-25T01:00:00Z" in text

  test "appending an alert produces a parseable kdl document":
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
