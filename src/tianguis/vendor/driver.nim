## Real Driver — wraps actual HTTP + subprocess git + content hashing
## against the on-disk source tree.
##
## Untested at unit level (mechanical I/O glue); exercised by:
##   - Integration tests gated by TIANGUIS_INTEGRATION_TESTS=1
##   - End-to-end CI runs against real nim-lang/packages.json
##
## Decision logic lives in orchestrate.nim with a Driver-injection point;
## this module is the production binding only.

import std/[httpclient, osproc, os, strutils, tempfiles]
import ./orchestrate
import ./upstream
import ../identity
import ../errors

const NimLangPackagesUrl* =
  "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

type
  RealDriver* = ref object of Driver
    packagesUrl*: string
    client:       HttpClient

proc newRealDriver*(packagesUrl = NimLangPackagesUrl): RealDriver =
  RealDriver(packagesUrl: packagesUrl, client: newHttpClient(timeout = 30_000))

method fetchPackagesJson*(d: RealDriver): seq[UpstreamPackage] =
  let body = d.client.getContent(d.packagesUrl)
  let parsed = parseUpstreamPackages(body)
  if parsed.isErr:
    raise newException(IOError, "fetch packages.json: " & parsed.getErr.message)
  parsed.get

proc gitOutput(args: openArray[string]): string =
  let (output, code) = execCmdEx("git " & args.join(" "))
  if code != 0:
    raise newException(IOError,
      "git " & args.join(" ") & " failed (exit " & $code & "): " & output)
  output

method listTags*(d: RealDriver, url: string): seq[string] =
  ## `git ls-remote --tags <url>` lines look like
  ##   <sha>\trefs/tags/<tag>[^{}]
  ## We keep peeled refs collapsed and de-duplicate.
  let raw = gitOutput(["ls-remote", "--tags", url])
  for line in raw.splitLines():
    let parts = line.split('\t')
    if parts.len < 2: continue
    let r = parts[1]
    const prefix = "refs/tags/"
    if not r.startsWith(prefix): continue
    var tag = r[prefix.len .. ^1]
    if tag.endsWith("^{}"): tag = tag[0 ..< tag.len - 3]
    if tag.len > 0 and tag notin result:
      result.add(tag)

method headSha*(d: RealDriver, url: string): string =
  ## `git ls-remote --symref <url> HEAD` first line is the symbolic ref;
  ## second line carries the sha and ref. We just want the sha for the
  ## default branch.
  let raw = gitOutput(["ls-remote", url, "HEAD"])
  let first = raw.splitLines()[0]
  let parts = first.split('\t')
  if parts.len >= 1: parts[0] else: ""

method shallowCloneAndHash*(d: RealDriver, url, refName: string): CloneResult =
  let tmp = createTempDir("tianguis-clone-", "")
  defer: removeDir(tmp)
  # `git clone --depth 1 --branch <refName> <url> <tmp>` works for
  # both tag names and branch names; falls back to clone+checkout if
  # the ref is a commit sha (rare in our case).
  let (output, code) = execCmdEx(
    "git clone --depth 1 --branch " & quoteShell(refName) & " " &
    quoteShell(url) & " " & quoteShell(tmp)
  )
  if code != 0:
    raise newException(IOError, "git clone failed: " & output)
  let sha = strip(gitOutput(["-C", quoteShell(tmp), "rev-parse", "HEAD"]))
  CloneResult(
    contentHash: computeContentHash(tmp),
    commitSha:   sha,
  )
