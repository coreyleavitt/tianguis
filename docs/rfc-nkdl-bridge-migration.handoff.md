# nkdl-bridge migration — handoff

- **Stage:** DONE — all slices implemented, verified through the real `nim.cfg`, committed.
- **Resume:** migration complete. Next tianguis work is unrelated (e.g. #32 identity).

## Slices — all code done + verified
- [x] S1 — dep bump (`milpa.kdl` `kdl`→`nkdl`, url→`nkdl.git`, re-resolved to main=50a5c11)
      + `import kdl`→`import nkdl` in all 4 files + re-export swap (`export nkdl, errors`)
- [x] S2 — `parseProvenance` + `parseRequires` ported to the DOM bridge
- [x] S3 — `parseVersion` + `parsePackage` + `parseKdl` ported; strict membership +
      line/col via `doc.lineMap.lineColOf(n.span.offset)`. **Both gate tests green.**
- [x] S4 — `vendor/denylist.nim` mini-walk ported (`node.name` / `node.argStr(0)`)
- [x] S5 — **full suite green (13/13 files) through the real milpa `nim.cfg`** (no
      override); real 1.5 MB `index.kdl` (2613 pkgs / 2614 versions) parses + re-emits
      **byte-identical** (Invariant 1 ✓ on real data); **milpa parses the same file → 2613
      pkgs** (Invariant 2 ✓).

## Open fork — CLOSED
`src_dir "src"` added to `nkdl/milpa.kdl` and **pushed to nkdl main (f3ce655)**. tianguis
re-resolved (nkdl pinned at f3ce655, `src_dir "src"`), `nim.cfg` now emits
`--path:"_deps/nkdl/src"`, full suite green with no override. (Note: forcing the `ref=main`
re-resolution required deleting the stale `nkdl` block from `milpa.lock` first — `milpa lock`
does not re-resolve an already-pinned mutable ref. Possible milpa ergonomics gap, not filed.)

**For the record — nkdl's own `milpa.kdl` had been missing `src_dir "src"`.** It declares `name "nkdl"` but no
`src_dir`, so milpa emits `--path:"_deps/nkdl"` (repo root) instead of `_deps/nkdl/src`,
and `import nkdl` can't resolve through the generated `nim.cfg`. nkdl's `.nimble` has
`srcDir = "src"`, but milpa treats `milpa.kdl` as authoritative and doesn't fall back.

- **Root-cause fix (recommended):** add `src_dir "src"` to `nkdl/milpa.kdl`, push to nkdl
  `main`, re-resolve tianguis (`milpa -C . lock && fetch`), drop the override, re-run suite.
  One line, low risk, reversible. **This amends RFC Invariant 4** ("no nkdl changes"): a
  *manifest-metadata* fix is needed — NOT an API/derive change, so the bridge-only thesis
  holds.
- Secondary (optional, file as milpa issue): milpa could warn/fall-back to `.nimble`
  `srcDir` when `milpa.kdl` omits `src_dir`. More general; not required to unblock.

The push is cross-repo + outward-facing, so it's surfaced rather than done autonomously.

## Key decisions (this session)
- **Bridge-only**, no nkdl derive growth (confirmed against the real schema).
- Bridge helpers named `argText`/`childText` (NOT `argStr`) to avoid shadowing nkdl's
  built-in `argStr(n,i): Option[string]`. `childText` = the scalar-child accessor.
- `parseKdl` parse-error path enriches via `pe.enriched(s, "<input>")` for line/col.
- `schema_version` read via `node.argInt(0)`; all string scalars via `argText`.
- Result-only sites (`json_io`, `upstream`) use `import nkdl` (umbrella re-exports `spans`);
  `import nkdl/spans` does NOT resolve under milpa's flat `src`-on-path layout.
- Invariants 1+2 proven on the real 1.5 MB index — strongest possible verification.

## Context
- Build/test (container, single file, override): `podman run --rm -v "$PWD":/work -w /work
  docker.io/nimlang/nim:2.2.0 nim c -r --hints:off --path:_deps/nkdl/src tests/test_<x>.nim`
- After the nkdl fix lands the override is unnecessary.
