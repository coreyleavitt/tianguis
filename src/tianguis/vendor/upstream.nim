## Parse nim-lang/packages.json into UpstreamPackage records.
##
## The shape is documented at nim-lang/packages — each entry has at
## minimum `name`, `url`, and `method`; many also carry `tags`,
## `description`, `license`, `web`, etc. We only consume the fields
## we need for vendoring (name + url + method); the rest are ignored.

import std/json
import nkdl  # for Result, ok, err (re-exported from nkdl/spans)
import ../errors

export nkdl, errors

type
  UpstreamPackage* = object
    name*:    string
    url*:     string
    `method`*: string   ## "git" today; other transports (hg, etc.) skipped

proc parseUpstreamPackages*(raw: string): Result[seq[UpstreamPackage], IdxError] =
  ## Parse a nim-lang/packages.json text into UpstreamPackage records.
  let node = try:
    parseJson(raw)
  except JsonParsingError as e:
    return err[seq[UpstreamPackage], IdxError](initIndexError(
      iecJsonParse, "malformed packages.json: " & e.msg
    ))
  if node.kind != JArray:
    return err[seq[UpstreamPackage], IdxError](initIndexError(
      iecBadType, "packages.json root must be an array, got " & $node.kind
    ))
  var entries: seq[UpstreamPackage] = @[]
  for item in node:
    entries.add(UpstreamPackage(
      name:     item{"name"}.getStr(""),
      url:      item{"url"}.getStr(""),
      `method`: item{"method"}.getStr(""),
    ))
  ok[seq[UpstreamPackage], IdxError](entries)
