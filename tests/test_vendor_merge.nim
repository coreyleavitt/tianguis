## Vendored-entry construction + merge-into-index tests.

import std/[unittest, tables, options]
import tianguis/[model, kdl_io]
import tianguis/vendor/[upstream, tagselect, merge]

const fixedPublishedAt = "2026-05-25T00:00:00Z"

proc fakeUpstream(name = "chronos"): UpstreamPackage =
  UpstreamPackage(
    name: name,
    url: "https://github.com/coreyleavitt/" & name,
    `method`: "git",
  )

suite "vendor build":
  test "buildVendoredEntry produces a milpa-vendored Version":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let entry = buildVendoredEntry(
      pkg, sel,
      contentHash = "sha256:abcdef",
      commitSha   = "deadbeef1234567",
      publishedAt = fixedPublishedAt,
    )
    check entry.package.name == "chronos"
    check entry.package.upstream == "https://github.com/coreyleavitt/chronos"
    check entry.version.version == "0.5.0"
    check entry.version.contentHash == "sha256:abcdef"
    check entry.version.attestation == "milpa-vendored"
    check entry.version.provenances.len == 1
    check entry.version.provenances[0].kind == pkGit
    check entry.version.provenances[0].gitRef == "v0.5.0"
    check entry.version.provenances[0].commitSha == "deadbeef1234567"

suite "vendor merge":
  test "merging into empty Index adds the package":
    let pkg = fakeUpstream()
    let sel = TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0")
    let e = buildVendoredEntry(pkg, sel, "sha256:a", "c123", fixedPublishedAt)
    let res = mergeVendored(Index(schemaVersion: 1, packages: @[]), e)
    check res.drift.isNone
    check res.index.packages.len == 1
    check res.index.packages[0].name == "chronos"
    check res.index.packages[0].versions.len == 1
    check res.index.packages[0].versions[0].version == "0.5.0"

  test "merging a new version onto an existing package appends":
    let pkg = fakeUpstream()
    let v0_4 = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.4.0", version: "0.4.0"),
      "sha256:older", "olderSha", fixedPublishedAt,
    )
    let v0_5 = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:newer", "newerSha", fixedPublishedAt,
    )
    let after_v0_4 = mergeVendored(Index(schemaVersion: 1, packages: @[]), v0_4)
    let after_v0_5 = mergeVendored(after_v0_4.index, v0_5)
    check after_v0_5.drift.isNone
    check after_v0_5.index.packages.len == 1
    check after_v0_5.index.packages[0].versions.len == 2

  test "merging existing (package, version) with same hash is idempotent":
    let pkg = fakeUpstream()
    let e = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:same", "abc", fixedPublishedAt,
    )
    let first = mergeVendored(Index(schemaVersion: 1, packages: @[]), e)
    let second = mergeVendored(first.index, e)
    check second.drift.isNone
    check second.index.packages[0].versions.len == 1  # not duplicated

  test "drift detected when existing (package, version) has different hash":
    let pkg = fakeUpstream()
    let oldEntry = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:original", "abc", fixedPublishedAt,
    )
    let newEntry = buildVendoredEntry(
      pkg, TagSelection(kind: tskSemver, tag: "v0.5.0", version: "0.5.0"),
      "sha256:forcepushed", "abc", fixedPublishedAt,
    )
    let initial = mergeVendored(Index(schemaVersion: 1, packages: @[]), oldEntry)
    let after = mergeVendored(initial.index, newEntry)
    check after.drift.isSome
    check after.drift.get.packageName == "chronos"
    check after.drift.get.version == "0.5.0"
    check after.drift.get.existingHash == "sha256:original"
    check after.drift.get.newHash == "sha256:forcepushed"
    # Existing entry retained verbatim — no silent update.
    check after.index.packages[0].versions[0].contentHash == "sha256:original"
