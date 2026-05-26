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
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SITE = Path(__file__).resolve().parents[1]
BUILD = SITE / "_build"
TEMPLATES = SITE / "templates"

REKOR_SEARCH = "https://search.sigstore.dev/?hash="


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


def render_version_block(ver: dict, pkg: dict) -> str:
    ver_str = html.escape(ver.get("version", ""))
    content_hash = ver.get("content_hash", "")
    content_hash_h = html.escape(content_hash)
    attestation = html.escape(ver.get("attestation", "unknown"))
    att_class = attestation_class(attestation)
    signed_by = html.escape(ver.get("signed_by", ""))
    published_at = html.escape(ver.get("published_at", ""))

    rekor_link = (
        f'<a href="{REKOR_SEARCH}{html.escape(content_hash)}" rel="noopener">search Rekor</a>'
        if content_hash else ""
    )

    provs = ver.get("provenances", [])
    prov_html = "\n".join(render_provenance(p) for p in provs) or "<em>no provenance</em>"

    return f"""\
<section class="version">
  <header class="version-head">
    <h3 class="version-num">{ver_str}</h3>
    <span class="{att_class} version-att">{attestation}</span>
    <span class="version-date">{published_at}</span>
  </header>
  <dl class="version-meta">
    <dt>content_hash</dt>
    <dd><code class="hash">{content_hash_h}</code> {rekor_link}</dd>
    <dt>signed_by</dt>
    <dd><code>{signed_by}</code></dd>
    <dt>provenance</dt>
    <dd>{prov_html}</dd>
  </dl>
</section>"""


def render_package_page(pkg: dict) -> str:
    namespace = html.escape(pkg.get("namespace", ""))
    name = html.escape(pkg.get("name", ""))
    upstream = html.escape(pkg.get("upstream", ""))
    versions = pkg.get("versions", [])

    latest = versions[0] if versions else None
    install_snippet = f'{name}'
    if latest:
        install_snippet = f'{name} >= {html.escape(latest.get("version",""))}'

    versions_html = "\n".join(render_version_block(v, pkg) for v in versions)

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
        (out_dir / f"{nm}.html").write_text(render_package_page(pkg))

    # Static content pages
    for tmpl, dest in [
        ("about.html", "about.html"),
        ("adoption.html", "adoption.html"),
        ("spec.html", "spec.html"),
    ]:
        if (TEMPLATES / tmpl).exists():
            (BUILD / dest).write_text(render_simple_page(tmpl))

    # Site assets
    shutil.copy(TEMPLATES / "style.css", BUILD / "style.css")
    shutil.copy(TEMPLATES / "robots.txt", BUILD / "robots.txt")
    shutil.copy(TEMPLATES / "CNAME", BUILD / "CNAME")

    # Raw registry files at canonical URLs.
    shutil.copy(index_kdl, BUILD / "index.kdl")
    shutil.copy(index_json, BUILD / "index.json")

    print(f"built {BUILD}/ — {len(packages)} packages, {len(packages)} detail pages")


if __name__ == "__main__":
    build()
