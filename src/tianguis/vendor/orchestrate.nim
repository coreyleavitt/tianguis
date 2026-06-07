## Pure orchestration of the vendor-en-absentia run.
##
## Driver-injected I/O means the entire decision graph (which packages
## to vendor, which tags to pick, when to flag drift, when to skip
## denylisted entries) is testable with fake drivers and deterministic
## inputs. The real driver (`driver.nim`) wraps subprocess calls to
## git + a HTTP client; this module never touches the network or disk
## directly.

import ./upstream
import ./tagselect
import ./merge
import ./denylist
import ./alerts
import ../model
import ../namespace

type
  CloneResult* = object
    contentHash*: string
    commitSha*:   string

  Driver* = ref object of RootObj

  VendorRunResult* = object
    index*:   Index
    alerts*:  string         ## full alerts.kdl log (existing + new)
    skipped*: seq[string]    ## denylisted or undrivable packages we skipped

# ---------------------------------------------------------------------------
# Driver protocol — concrete drivers override these.
# ---------------------------------------------------------------------------

method fetchPackagesJson*(d: Driver): seq[UpstreamPackage] {.base.} =
  raise newException(Defect, "abstract Driver.fetchPackagesJson called")

method listTags*(d: Driver, url: string): seq[string] {.base.} =
  raise newException(Defect, "abstract Driver.listTags called")

method headSha*(d: Driver, url: string): string {.base.} =
  raise newException(Defect, "abstract Driver.headSha called")

method shallowCloneAndHash*(d: Driver, url, refName: string): CloneResult {.base.} =
  raise newException(Defect, "abstract Driver.shallowCloneAndHash called")

# ---------------------------------------------------------------------------
# Pure orchestrator
# ---------------------------------------------------------------------------

proc runVendor*(
    driver:        Driver,
    initialIndex:  Index,
    denylist:      Denylist,
    initialAlerts: string,
    nowIso:        string,
): VendorRunResult =
  ## Walk every upstream package; for each one not denylisted, fetch
  ## tags + HEAD, select the right tag, shallow-clone-and-hash, merge
  ## the resulting entry into the index. Drift and collision alerts append
  ## to the alerts log.
  var idx = initialIndex
  var alerts = initialAlerts
  var skipped: seq[string] = @[]

  for pkg in driver.fetchPackagesJson():
    if pkg.`method` != "git":
      # Non-git transports get their own vendoring path when their
      # fetcher lands; skip silently for now.
      continue

    # Derive namespace up front from the git provenance URL.
    # If underivable → log + skip + continue (auditable, not silent).
    let nsResult = deriveNamespace(pkg.url)
    if nsResult.isErr:
      stderr.writeLine("tianguis: vendor: " & pkg.name &
        " skipped (undeivable namespace, " & $nsResult.error & "): " & pkg.url)
      skipped.add(pkg.name)
      continue
    let ns = namespaceString(nsResult.get)

    # Denylist check is tuple-keyed: (namespace, name).
    if denylist.contains(ns, pkg.name):
      skipped.add(pkg.name)
      continue

    # Per-package isolation: a single bad upstream (deleted repo, network
    # blip, weird git state) must not abort the entire vendor pass. We
    # log + skip + continue, leaving the rest of the catalog to vendor.
    try:
      let tags = driver.listTags(pkg.url)
      let head = driver.headSha(pkg.url)
      let sel = selectTag(tags, head)
      let refName = if sel.tag.len > 0: sel.tag else: "HEAD"
      let clone = driver.shallowCloneAndHash(pkg.url, refName)

      let entryResult = buildVendoredEntry(
        pkg, sel,
        contentHash = clone.contentHash,
        commitSha   = clone.commitSha,
        publishedAt = nowIso,
      )
      # buildVendoredEntry already checked derivability; if it errors
      # here it's a logic bug, but be robust.
      if entryResult.isErr:
        stderr.writeLine("tianguis: vendor: " & pkg.name &
          " skipped (buildVendoredEntry err, " & $entryResult.error & "): " & pkg.url)
        skipped.add(pkg.name)
        continue

      let entry = entryResult.get
      let (newIdx, outcome) = mergeVendored(idx, entry)
      case outcome.kind
      of mokAdded:
        # Only commit the mutated index on an actual add.
        idx = newIdx
      of mokIdempotent:
        # Safe no-op write avoided — index already contains identical entry.
        discard
      of mokIdentityDrift:
        alerts = appendAlert(alerts, outcome.identity, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-IDENTITY-DRIFT: " &
          outcome.identity.name &
          " stored=" & outcome.identity.storedNamespace &
          " rederived=" & outcome.identity.rederivedNamespace)
      of mokCollision:
        let col = outcome.collision
        alerts = appendAlert(alerts, col, detectedAt = nowIso)
        stderr.writeLine("tianguis: vendor: IDX-INTRAORG-COLLISION: " &
          col.namespace & "/" & col.name &
          " existing=" & col.existingRepo & " incoming=" & col.newRepo)
      of mokContentDrift:
        alerts = appendAlert(alerts, outcome.content, detectedAt = nowIso)
    except CatchableError as e:
      stderr.writeLine("tianguis: vendor: " & pkg.name & " skipped: " & e.msg)
      skipped.add(pkg.name)
      continue

  VendorRunResult(index: idx, alerts: alerts, skipped: skipped)
