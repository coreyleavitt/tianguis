"""Build the static tianguis.dev site from index.json.

Reads <repo>/index.json + the static templates in site/templates/, emits
site/_build/ ready to upload to GH Pages. Pure stdlib; no dependencies.

Output structure:
  _build/
    index.html              — landing page + filterable package list
    p/<namespace>/<name>.html  — per-package detail pages
    about.html              — registry model + why content-addressed
    adoption.html           — how to publish
    spec.html               — links to RFCs + index format spec
    index.kdl               — canonical registry (milpa consumes this)
    index.json              — JSON projection (milpa or third parties)
    robots.txt              — noindex hints during soft-launch
    CNAME                   — custom domain
    style.css               — shared styling
"""
from __future__ import annotations

import html
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import markdown

import markdown as md


REPO = Path(__file__).resolve().parents[2]
SITE = Path(__file__).resolve().parents[1]
BUILD = SITE / "_build"
TEMPLATES = SITE / "templates"
CACHE = SITE / "_cache"

# search.sigstore.dev accepts a direct logIndex query that opens the
# specific Rekor entry — far better UX than the artifact-hash search
# which doesn't index by what users have on hand (the OCI digest).
REKOR_URL_BY_INDEX = "https://search.sigstore.dev/?logIndex="


def fmt_iso(ts: str) -> str:
    try:
        return ts.split("T", 1)[0]
    except Exception:
        return ts


def attestation_class(attestation: str) -> str:
    return "att-author" if attestation == "author-signed" else "att-vendored"


def pkg_url(pkg: dict) -> str:
    """Canonical site path for a package."""
    return f"/p/{pkg.get('namespace','')}/{pkg.get('name','')}.html"


# ---------------------------------------------------------------------------
# Rekor logIndex lookup — runs `cosign verify` once per author-signed OCI
# artifact, extracts the bundle's logIndex, caches it in site/_cache/.
#
# logIndex is immutable per signature (Rekor is append-only with monotonic
# indexes), so the cache is permanently valid for any OCI digest we've
# already seen. The cache file is committed to the repo so subsequent
# builds (and offline rebuilds) don't need to re-verify.
# ---------------------------------------------------------------------------


CACHE_FILE = CACHE / "rekor-logindex.json"


def load_rekor_cache() -> dict[str, int]:
    if CACHE_FILE.exists():
        try:
            return json.loads(CACHE_FILE.read_text())
        except json.JSONDecodeError:
            return {}
    return {}


def save_rekor_cache(cache: dict[str, int]) -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    CACHE_FILE.write_text(json.dumps(cache, indent=2, sort_keys=True) + "\n")


def lookup_logindex(
    oci_ref: str,
    signed_by_pattern: str,
    cache: dict[str, int],
) -> int | None:
    """Return the Rekor logIndex for `oci_ref`, consulting cache first.

    Returns None if cosign isn't available, the verify fails, or the
    output doesn't include a logIndex (any of which mean we render the
    page without a Rekor link rather than failing the build).
    """
    if oci_ref in cache:
        return cache[oci_ref]
    if not shutil.which("cosign"):
        return None
    try:
        result = subprocess.run(
            [
                "cosign", "verify",
                "--certificate-identity-regexp", signed_by_pattern,
                "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com",
                oci_ref,
            ],
            capture_output=True, timeout=60,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout.decode("utf-8", "replace"))
        # cosign verify emits an array of signatures; take the first
        # entry's bundle's logIndex.
        log_index = int(payload[0]["optional"]["Bundle"]["Payload"]["logIndex"])
    except (json.JSONDecodeError, KeyError, IndexError, ValueError, TypeError):
        return None
    cache[oci_ref] = log_index
    return log_index


# ---------------------------------------------------------------------------
# Index (landing) rendering
# ---------------------------------------------------------------------------


def render_pkg_list_item(pkg: dict) -> str:
    versions = pkg.get("versions", [])
    namespace = html.escape(pkg.get("namespace", ""))
    name = html.escape(pkg.get("name", ""))
    detail = html.escape(pkg_url(pkg))

    latest = versions[0] if versions else None
    version_count = len(versions)
    if latest:
        latest_ver = html.escape(latest.get("version", ""))
        attestation = html.escape(latest.get("attestation", "unknown"))
        att_class = attestation_class(attestation)
        published_at = fmt_iso(latest.get("published_at", ""))
        meta = f'<span class="{att_class}">{attestation}</span> · {published_at}'
    else:
        latest_ver = "—"
        meta = '<span class="att-vendored">no versions</span>'

    return f"""\
<li class="pkg" data-name="{name}" data-namespace="{namespace}">
  <div class="pkg-head">
    <span class="pkg-ns">{namespace}/</span><a class="pkg-name" href="{detail}">{name}</a>
    <span class="pkg-ver">{latest_ver}</span>
  </div>
  <div class="pkg-meta">{meta} · {version_count} version{'s' if version_count != 1 else ''}</div>
</li>
"""


def render_recent_item(pkg: dict, ver: dict) -> str:
    namespace = html.escape(pkg.get("namespace", ""))
    name = html.escape(pkg.get("name", ""))
    detail = html.escape(pkg_url(pkg))
    ver_str = html.escape(ver.get("version", ""))
    attestation = html.escape(ver.get("attestation", "unknown"))
    att_class = attestation_class(attestation)
    published_at = fmt_iso(ver.get("published_at", ""))
    return f"""\
<li class="recent-item">
  <a class="recent-name" href="{detail}">{namespace}/{name}</a>
  <span class="recent-ver">{ver_str}</span>
  <span class="{att_class} recent-att">{attestation}</span>
  <span class="recent-date">{published_at}</span>
</li>"""


def render_landing(packages: list, build_time_iso: str, commit_sha: str) -> str:
    pkg_list_html = "\n".join(render_pkg_list_item(p) for p in packages)

    # Counts by attestation level (look at most recent version per pkg).
    n_author = sum(
        1 for p in packages
        if p.get("versions") and p["versions"][0].get("attestation") == "author-signed"
    )
    n_vendored = sum(
        1 for p in packages
        if p.get("versions") and p["versions"][0].get("attestation") == "milpa-vendored"
    )

    # Recent activity: flatten (pkg, version) pairs, take newest 10 by published_at.
    flat = [
        (p, v) for p in packages for v in p.get("versions", [])
        if v.get("published_at")
    ]
    flat.sort(key=lambda pv: pv[1].get("published_at", ""), reverse=True)
    recent_html = "\n".join(render_recent_item(p, v) for p, v in flat[:10])

    tmpl = (TEMPLATES / "index.html").read_text()
    return (
        tmpl
        .replace("{{PACKAGE_COUNT}}", str(len(packages)))
        .replace("{{N_AUTHOR}}", str(n_author))
        .replace("{{N_VENDORED}}", str(n_vendored))
        .replace("{{PACKAGES}}", pkg_list_html)
        .replace("{{RECENT}}", recent_html)
        .replace("{{BUILD_TIME}}", html.escape(build_time_iso))
        .replace("{{COMMIT_SHA}}", html.escape(commit_sha[:7]))
    )


# ---------------------------------------------------------------------------
# Per-package detail rendering
# ---------------------------------------------------------------------------


def render_provenance(prov: dict) -> str:
    kind = prov.get("kind", "")
    if kind == "oci":
        registry = html.escape(prov.get("registry", ""))
        repository = html.escape(prov.get("repository", ""))
        digest = html.escape(prov.get("digest", ""))
        ref = f"{registry}/{repository}@{digest}"
        return f"""\
<div class="prov prov-oci">
  <span class="prov-kind">OCI</span>
  <code class="prov-ref">{ref}</code>
</div>"""
    elif kind == "git":
        url = html.escape(prov.get("url", ""))
        sha = html.escape(prov.get("commit_sha", ""))
        return f'<div class="prov prov-git"><span class="prov-kind">git</span> <a href="{url}">{url}</a> <code>{sha[:12]}</code></div>'
    else:
        return f'<div class="prov"><span class="prov-kind">{html.escape(kind)}</span></div>'


def render_version_block(ver: dict, pkg: dict, rekor_cache: dict[str, int]) -> str:
    ver_str = html.escape(ver.get("version", ""))
    content_hash = ver.get("content_hash", "")
    content_hash_h = html.escape(content_hash)
    attestation = html.escape(ver.get("attestation", "unknown"))
    att_class = attestation_class(attestation)
    signed_by_raw = ver.get("signed_by", "")
    signed_by = html.escape(signed_by_raw)
    published_at = html.escape(ver.get("published_at", ""))

    provs = ver.get("provenances", [])
    oci_provs = [p for p in provs if p.get("kind") == "oci" and p.get("digest")]
    prov_html = "\n".join(render_provenance(p) for p in provs) or "<em>no provenance</em>"

    # Verification: link to the Rekor entry (resolved at build time via
    # cosign verify, cached by OCI digest) + a copy-paste `cosign verify`
    # snippet for users who want to run the math themselves.
    verify_block = ""
    if oci_provs and signed_by_raw:
        op = oci_provs[0]
        oci_ref = f'{op["registry"]}/{op["repository"]}@{op["digest"]}'
        identity_pattern = signed_by_raw + "@.*"
        log_index = lookup_logindex(oci_ref, identity_pattern, rekor_cache)
        rekor_link = ""
        if log_index is not None:
            rekor_link = (
                f' · <a href="{REKOR_URL_BY_INDEX}{log_index}" rel="noopener">view in Rekor</a>'
            )
        verify_block = f"""\
  <dt>verify</dt>
  <dd>
    <details>
      <summary>cosign verify command{rekor_link}</summary>
      <pre><code>cosign verify \\
  --certificate-identity-regexp '{html.escape(identity_pattern)}' \\
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \\
  {html.escape(oci_ref)}</code></pre>
    </details>
  </dd>"""

    return f"""\
<section class="version">
  <header class="version-head">
    <h3 class="version-num">{ver_str}</h3>
    <span class="{att_class} version-att">{attestation}</span>
    <span class="version-date">{published_at}</span>
  </header>
  <dl class="version-meta">
    <dt>content_hash</dt>
    <dd><code class="hash">{content_hash_h}</code> <span class="hash-hint">milpa-computed; verify by fetching and rehashing</span></dd>
    <dt>signed_by</dt>
    <dd><code>{signed_by}</code></dd>
    <dt>provenance</dt>
    <dd>{prov_html}</dd>
{verify_block}
  </dl>
</section>"""


def render_package_page(pkg: dict, rekor_cache: dict[str, int]) -> str:
    namespace = html.escape(pkg.get("namespace", ""))
    name = html.escape(pkg.get("name", ""))
    upstream = html.escape(pkg.get("upstream", ""))
    versions = pkg.get("versions", [])

    latest = versions[0] if versions else None
    install_snippet = f'{name}'
    if latest:
        install_snippet = f'{name} >= {html.escape(latest.get("version",""))}'

    versions_html = "\n".join(render_version_block(v, pkg, rekor_cache) for v in versions)

    tmpl = (TEMPLATES / "package.html").read_text()
    return (
        tmpl
        .replace("{{NAMESPACE}}", namespace)
        .replace("{{NAME}}", name)
        .replace("{{UPSTREAM}}", upstream)
        .replace("{{VERSION_COUNT}}", str(len(versions)))
        .replace("{{INSTALL_SNIPPET}}", install_snippet)
        .replace("{{VERSIONS}}", versions_html)
    )


# ---------------------------------------------------------------------------
# Static content pages (about, adoption, spec)
# ---------------------------------------------------------------------------


def render_simple_page(template_name: str) -> str:
    return (TEMPLATES / template_name).read_text()


# ---------------------------------------------------------------------------
# Markdown rendering — for the deep-dive docs the spec page links into.
# Wraps the rendered HTML in our site chrome (header/footer/nav).
# ---------------------------------------------------------------------------


MD_DOC_WRAPPER = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{title} — tianguis</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<header>
  <div class="header-inner">
    <a href="/" class="brand">
      <img src="/favicon.svg" alt="" class="brand-icon" width="48" height="48">
      <div class="brand-text">
        <h1>tianguis</h1>
        <p class="tagline">an open-air market for Nim packages</p>
      </div>
    </a>
    <nav class="topnav">
      <a href="/about.html">about</a>
      <a href="/adoption.html">publish</a>
      <a href="/spec.html">spec</a>
      <a href="https://github.com/coreyleavitt/tianguis">source</a>
    </nav>
  </div>
</header>
<main class="prose md-doc">
<nav class="crumb"><a href="/spec.html">← spec</a></nav>
{body}
<hr>
<p class="md-source">
  view source: <a href="{source_url}"><code>{source_path}</code></a>
</p>
</main>
<footer><p><a href="/">← back to registry</a></p></footer>
</body>
</html>
"""


def extract_title(md_text: str, fallback: str) -> str:
    """Pull the first H1 from a markdown doc, or fall back to filename."""
    for line in md_text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return fallback


def render_md_doc(src: Path, out: Path, repo_rel_path: str) -> None:
    """Render a markdown file to HTML, wrapped in site chrome."""
    md_text = src.read_text()
    title = extract_title(md_text, src.stem)
    body = markdown.markdown(
        md_text,
        extensions=["fenced_code", "tables", "toc", "attr_list"],
        output_format="html5",
    )
    page = MD_DOC_WRAPPER.format(
        title=html.escape(title),
        body=body,
        source_path=html.escape(repo_rel_path),
        source_url=f"https://github.com/coreyleavitt/tianguis/blob/main/{repo_rel_path}",
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(page)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def build() -> None:
    index_json = REPO / "index.json"
    index_kdl = REPO / "index.kdl"
    if not index_json.exists():
        print(f"FATAL: {index_json} missing — run tianguis project first", file=sys.stderr)
        sys.exit(1)

    data = json.loads(index_json.read_text())
    packages = data.get("packages", [])
    packages.sort(key=lambda p: (p.get("namespace", ""), p.get("name", "")))

    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    import os
    commit_sha = os.environ.get("GITHUB_SHA", data.get("generated_at", "local"))

    rekor_cache = load_rekor_cache()
    initial_cache_size = len(rekor_cache)

    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)

    # Landing
    (BUILD / "index.html").write_text(render_landing(packages, now_iso, commit_sha))

    # Per-package detail pages → /p/<namespace>/<name>.html
    pkg_root = BUILD / "p"
    for pkg in packages:
        ns = pkg.get("namespace", "")
        nm = pkg.get("name", "")
        if not ns or not nm:
            continue
        out_dir = pkg_root / ns
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{nm}.html").write_text(render_package_page(pkg, rekor_cache))

    if len(rekor_cache) > initial_cache_size:
        save_rekor_cache(rekor_cache)
        print(f"  rekor cache: {len(rekor_cache) - initial_cache_size} new entries → {CACHE_FILE.relative_to(REPO)}")

    # Static content pages
    for tmpl, dest in [
        ("about.html", "about.html"),
        ("adoption.html", "adoption.html"),
        ("spec.html", "spec.html"),
    ]:
        if (TEMPLATES / tmpl).exists():
            (BUILD / dest).write_text(render_simple_page(tmpl))

    # Deep-dive docs (rendered from markdown sources, mirroring repo paths).
    # The /spec.html narrative page links into these for normative detail.
    md_docs = [
        ("docs/spec/index-format.md", "docs/spec/index-format.html"),
        ("docs/rfc-registry.md", "docs/rfc-registry.html"),
        ("docs/adoption/github.md", "docs/adoption/github.html"),
        ("docs/adoption/any-ci.md", "docs/adoption/any-ci.html"),
    ]
    rendered_docs = 0
    for src_rel, out_rel in md_docs:
        src = REPO / src_rel
        if not src.exists():
            continue
        render_md_doc(src, BUILD / out_rel, src_rel)
        rendered_docs += 1

    # Site assets
    shutil.copy(TEMPLATES / "style.css", BUILD / "style.css")
    shutil.copy(TEMPLATES / "robots.txt", BUILD / "robots.txt")
    shutil.copy(TEMPLATES / "CNAME", BUILD / "CNAME")
    shutil.copy(TEMPLATES / "icon.svg", BUILD / "favicon.svg")

    # Raw registry files at canonical URLs.
    shutil.copy(index_kdl, BUILD / "index.kdl")
    shutil.copy(index_json, BUILD / "index.json")

    print(f"built {BUILD}/ — {len(packages)} packages, {len(packages)} detail pages, {rendered_docs} md docs")


if __name__ == "__main__":
    build()
