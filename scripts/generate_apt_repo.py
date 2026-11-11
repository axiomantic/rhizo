#!/usr/bin/env python3
"""
generate_apt_repo.py
Generates an APT repository structure (Packages, Packages.gz, Release, index.html)
from Debian (.deb) packages, and renders the Rhizo Documentation & Package Portal.
"""
import argparse
import gzip
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Try to import companion docs generator
SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
try:
    import generate_docs_site
except ImportError:
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    import generate_docs_site


def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def md5_file(filepath):
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def extract_control_info(deb_path):
    """Extracts control fields from .deb package via dpkg-deb or ar."""
    if shutil.which("dpkg-deb"):
        out = subprocess.check_output(["dpkg-deb", "-f", deb_path], text=True).strip()
        return out

    # Fallback using ar and tar if dpkg-deb is not available
    import tempfile
    import tarfile

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["ar", "x", deb_path], cwd=tmp, check=True)
        control_tar = None
        for cand in ["control.tar.gz", "control.tar.xz", "control.tar.zst"]:
            p = os.path.join(tmp, cand)
            if os.path.isfile(p):
                control_tar = p
                break
        if control_tar and not control_tar.endswith(".zst"):
            with tarfile.open(control_tar, "r:*") as tar:
                member = tar.extractfile("./control") or tar.extractfile("control")
                if member:
                    return member.read().decode("utf-8").strip()

    # Fallback to minimal control based on filename
    basename = os.path.basename(deb_path)
    parts = basename.replace(".deb", "").split("_")
    pkg = parts[0] if len(parts) > 0 else "rhizo"
    ver = parts[1] if len(parts) > 1 else "0.2.32"
    arch = parts[2] if len(parts) > 2 else "amd64"
    return f"Package: {pkg}\nVersion: {ver}\nArchitecture: {arch}\nMaintainer: Axiomantic <info@axiomantic.org>\nDescription: Rhizo Inter-Assistant Redis Bus"


def generate_apt_repo(debs_dir: Path, apt_out_dir: Path):
    """Generates Packages, Packages.gz, Release, and apt/index.html."""
    apt_out_dir.mkdir(parents=True, exist_ok=True)

    # Filter out any legacy locutus packages
    deb_files = [
        f for f in os.listdir(debs_dir)
        if f.endswith(".deb") and not f.startswith("locutus_")
    ]
    if not deb_files:
        print(f"Warning: No valid Rhizo .deb files found in {debs_dir}")

    packages_entries = []

    for deb in sorted(deb_files):
        deb_path = os.path.join(debs_dir, deb)
        dest_deb = os.path.join(apt_out_dir, deb)
        if deb_path != dest_deb:
            shutil.copy2(deb_path, dest_deb)

        control_output = extract_control_info(dest_deb)
        size = os.path.getsize(dest_deb)
        sha256 = sha256_file(dest_deb)
        md5 = md5_file(dest_deb)

        entry = f"{control_output}\nFilename: {deb}\nSize: {size}\nMD5sum: {md5}\nSHA256: {sha256}\n"
        packages_entries.append(entry)

    packages_content = "\n".join(packages_entries) + ("\n" if packages_entries else "")
    packages_path = os.path.join(apt_out_dir, "Packages")
    with open(packages_path, "w", encoding="utf-8") as f:
        f.write(packages_content)

    packages_gz_path = os.path.join(apt_out_dir, "Packages.gz")
    with gzip.open(packages_gz_path, "wb") as gz:
        gz.write(packages_content.encode("utf-8"))

    # Generate Release file
    release_lines = [
        "Origin: Axiomantic",
        "Label: Rhizo",
        "Suite: stable",
        "Codename: stable",
        "Architectures: amd64 arm64",
        "Components: main",
        "Description: Axiomantic Rhizo Debian/Ubuntu APT Repository",
        "MD5Sum:",
    ]

    for fname in ["Packages", "Packages.gz"]:
        fpath = os.path.join(apt_out_dir, fname)
        sz = os.path.getsize(fpath)
        m = md5_file(fpath)
        release_lines.append(f" {m} {sz} {fname}")

    release_lines.append("SHA256:")
    for fname in ["Packages", "Packages.gz"]:
        fpath = os.path.join(apt_out_dir, fname)
        sz = os.path.getsize(fpath)
        s = sha256_file(fpath)
        release_lines.append(f" {s} {sz} {fname}")

    release_path = os.path.join(apt_out_dir, "Release")
    with open(release_path, "w", encoding="utf-8") as f:
        f.write("\n".join(release_lines) + "\n")

    # Generate APT Index page
    apt_html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Axiomantic Rhizo APT Repository</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 800px; margin: 40px auto; padding: 0 20px; line-height: 1.6; color: #24292e; background: #ffffff; }
    @media (prefers-color-scheme: dark) {
      body { background: #0d1117; color: #e6edf3; }
      pre { background: #161b22 !important; border-color: #30363d !important; color: #e6edf3; }
      h1, h2 { border-color: #30363d !important; }
      a { color: #58a6ff !important; }
    }
    pre { background: #f6f8fa; padding: 16px; border-radius: 6px; overflow: auto; border: 1px solid #e1e4e8; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 0.9em; }
    h1 { border-bottom: 1px solid #eaecef; padding-bottom: 10px; }
    h2 { margin-top: 1.5em; border-bottom: 1px solid #eaecef; padding-bottom: 6px; }
    a { color: #0969da; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .nav-bar { margin-bottom: 24px; padding-bottom: 12px; border-bottom: 1px solid #e1e4e8; display: flex; gap: 16px; font-weight: 500; font-size: 0.95rem; }
  </style>
</head>
<body>
  <div class="nav-bar">
    <a href="../index.html">&larr; Documentation Portal</a>
    <a href="https://github.com/axiomantic/rhizo" target="_blank" rel="noopener">GitHub</a>
    <a href="https://www.npmjs.com/package/@axiomantic/rhizo" target="_blank" rel="noopener">npm</a>
  </div>

  <h1>Axiomantic Rhizo APT Repository</h1>
  <p>Official Debian/Ubuntu package repository for <strong>Rhizo</strong> (amd64 &amp; arm64 architectures).</p>

  <h2>Installation via APT</h2>
  <pre><code># 1. Add repository to sources
echo "deb [trusted=yes] https://axiomantic.github.io/rhizo/apt/ ./" | sudo tee /etc/apt/sources.list.d/rhizo.list

# 2. Update and install
sudo apt-get update
sudo apt-get install -y rhizo</code></pre>

  <h2>Homebrew Installation (macOS &amp; Linux)</h2>
  <pre><code>brew install axiomantic/tap/rhizo</code></pre>

  <h2>npm Installation (Global)</h2>
  <pre><code>npm install -g @axiomantic/rhizo</code></pre>

  <h2>Universal One-Line Installer</h2>
  <pre><code>curl -fsSL https://raw.githubusercontent.com/axiomantic/rhizo/main/scripts/install.sh | bash</code></pre>

  <p style="margin-top: 2em; padding-top: 1em; border-top: 1px solid #eaecef;">
    For comprehensive architecture guides, CLI specifications, and wire protocols, visit the
    <a href="../index.html">Rhizo Documentation Portal</a> or the
    <a href="https://github.com/axiomantic/rhizo">Rhizo GitHub Repository</a>.
  </p>
</body>
</html>
"""
    with open(os.path.join(apt_out_dir, "index.html"), "w", encoding="utf-8") as f:
        f.write(apt_html)

    print(f"APT repository successfully generated in {apt_out_dir} ({len(deb_files)} packages)")


def main():
    parser = argparse.ArgumentParser(description="Generate Rhizo APT Repository & Documentation Portal")
    parser.add_argument("debs_dir", help="Directory containing .deb packages")
    parser.add_argument("apt_output_dir", help="Output directory for APT repository files")
    parser.add_argument("--site-dir", help="Root directory for GitHub Pages portal (index.html, docs/, apt/)")
    parser.add_argument("--docs-dir", help="Path to docs/ directory")
    parser.add_argument("--readme", help="Path to README.md")
    parser.add_argument("--skip-docs", action="store_true", help="Skip generating documentation portal")

    args = parser.parse_args()

    debs_dir = Path(os.path.abspath(args.debs_dir))
    apt_out_dir = Path(os.path.abspath(args.apt_output_dir))
    site_dir = Path(os.path.abspath(args.site_dir)) if args.site_dir else None

    # 1. Generate APT repository
    generate_apt_repo(debs_dir, apt_out_dir)

    # 2. Generate documentation portal
    if not args.skip_docs:
        readme_path = Path(args.readme) if args.readme else (REPO_ROOT / "README.md")
        docs_source_dir = Path(args.docs_dir) if args.docs_dir else (REPO_ROOT / "docs")

        # Determine target site directory
        target_site = site_dir or (apt_out_dir.parent if apt_out_dir.name == "apt" else apt_out_dir)
        target_site.mkdir(parents=True, exist_ok=True)

        print(f"Generating Rhizo Documentation Portal in {target_site}...")

        # Portal root index.html
        portal_html = generate_docs_site.generate_portal_home(readme_path, root_prefix="./")
        portal_index_path = target_site / "index.html"
        portal_index_path.write_text(portal_html, encoding="utf-8")
        print(f"Generated Portal Home: {portal_index_path}")

        # Render docs/*.html
        generate_docs_site.generate_docs_pages(REPO_ROOT, target_site, root_prefix="../")

        # If site_dir is distinct from apt_out_dir, ensure site_dir/apt contains the apt files
        if site_dir and site_dir != apt_out_dir:
            site_apt = site_dir / "apt"
            if site_apt != apt_out_dir:
                site_apt.mkdir(parents=True, exist_ok=True)
                for item in apt_out_dir.iterdir():
                    dest = site_apt / item.name
                    if item.is_file():
                        shutil.copy2(item, dest)
                    elif item.is_dir():
                        shutil.copytree(item, dest, dirs_exist_ok=True)

        # Create .nojekyll in site root
        nojekyll = target_site / ".nojekyll"
        nojekyll.touch()

    print("Site generation complete!")


if __name__ == "__main__":
    main()
