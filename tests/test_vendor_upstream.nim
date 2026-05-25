## Tests for parsing nim-lang/packages.json into UpstreamPackage records.
## The bot's first job is consuming this seed list.

import std/unittest
import tianguis/vendor/upstream

suite "upstream parse":
  test "single entry parses into UpstreamPackage":
    let raw = """
[
  {
    "name": "chronos",
    "url": "https://github.com/status-im/nim-chronos",
    "method": "git",
    "tags": ["async"],
    "description": "async framework"
  }
]
"""
    let parsed = parseUpstreamPackages(raw)
    check parsed.isOk
    let entries = parsed.get
    check entries.len == 1
    check entries[0].name == "chronos"
    check entries[0].url == "https://github.com/status-im/nim-chronos"
    check entries[0].`method` == "git"
