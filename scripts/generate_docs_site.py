#!/usr/bin/env python3
"""
generate_docs_site.py
Generates a static, responsive, zero-dependency documentation portal for Rhizo.
Parses markdown files into clean HTML with navigation, syntax styling, mermaid support,
and installation instructions for all 5 package managers.
"""

import html
import os
import re
import sys
from pathlib import Path


DOCS_MANIFEST = [
    {
        "slug": "architecture",
        "title": "System Architecture",
        "description": "Redis keyspace hierarchy, 27 atomic Lua scripts, and EVALSHA caching engine.",
        "icon": "🏗️",
        "source": "docs/architecture.md",
    },
    {
        "slug": "cli_reference",
        "title": "CLI Reference",
        "description": "Complete command-line interface documentation for all subcommands and flags.",
        "icon": "⌨️",
        "source": "docs/cli_reference.md",
    },
    {
        "slug": "configuration",
        "title": "Configuration Guide",
        "description": "Global, project, and environment configuration cascade with full provenance tracking.",
        "icon": "⚙️",
        "source": "docs/configuration.md",
    },
    {
        "slug": "routes_schema",
        "title": "Routes Schema",
        "description": "YAML specification for cascading System 1 task routing rules and queue mappings.",
        "icon": "🗺️",
        "source": "docs/routes_schema.md",
    },
    {
        "slug": "system_one_routing",
        "title": "System 1 Routing",
        "description": "Zero-config semantic triage accelerator with multi-tier route fallback.",
        "icon": "⚡",
        "source": "docs/system_one_routing.md",
    },
    {
        "slug": "wire_protocol",
        "title": "Wire Protocol",
        "description": "HMAC-SHA256 authenticated envelope, Ed25519 session signatures, and prompt firewall.",
        "icon": "🔒",
        "source": "docs/wire_protocol.md",
    },
    {
        "slug": "wism_state_machine",
        "title": "WISM State Machine",
        "description": "Unified Work Item State Machine with monotonic fencing tokens and dead-letter queues.",
        "icon": "🔄",
        "source": "docs/wism_state_machine.md",
    },
]

SITE_CSS = """
:root {
  --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  --font-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --bg-primary: #ffffff;
  --bg-secondary: #f6f8fa;
  --bg-tertiary: #eaeef2;
  --text-primary: #1f2328;
  --text-secondary: #656d76;
  --text-muted: #8c959f;
  --border-default: #d0d7de;
  --border-muted: #e1e4e8;
  --color-accent: #0969da;
  --color-accent-hover: #0550ae;
  --color-accent-subtle: #ddf4ff;
  --color-success: #1a7f37;
  --color-warning: #9a6700;
  --color-danger: #cf222e;
  --card-bg: #ffffff;
  --card-border: #d0d7de;
  --code-bg: #f6f8fa;
  --sidebar-width: 280px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg-primary: #0d1117;
    --bg-secondary: #161b22;
    --bg-tertiary: #21262d;
    --text-primary: #e6edf3;
    --text-secondary: #8b949e;
    --text-muted: #6e7681;
    --border-default: #30363d;
    --border-muted: #21262d;
    --color-accent: #2f81f7;
    --color-accent-hover: #58a6ff;
    --color-accent-subtle: rgba(56, 139, 253, 0.15);
    --card-bg: #161b22;
    --card-border: #30363d;
    --code-bg: #161b22;
  }
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  font-family: var(--font-sans);
  font-size: 16px;
  line-height: 1.6;
  color: var(--text-primary);
  background: var(--bg-primary);
  margin: 0;
  padding: 0;
}

a { color: var(--color-accent); text-decoration: none; }
a:hover { text-decoration: underline; color: var(--color-accent-hover); }

/* Navigation Header */
header.site-header {
  position: sticky;
  top: 0;
  z-index: 100;
  background: var(--bg-primary);
  border-bottom: 1px solid var(--border-default);
  backdrop-filter: blur(10px);
}
.header-inner {
  max-width: 1280px;
  margin: 0 auto;
  padding: 12px 24px;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  font-weight: 700;
  font-size: 1.25rem;
  color: var(--text-primary);
  text-decoration: none;
}
.brand .logo-badge {
  background: linear-gradient(135deg, #2f81f7, #a371f7);
  color: white;
  padding: 4px 8px;
  border-radius: 6px;
  font-size: 0.9rem;
  font-family: var(--font-mono);
}
.nav-links {
  display: flex;
  align-items: center;
  gap: 20px;
  font-size: 0.95rem;
}
.nav-links a {
  color: var(--text-secondary);
  text-decoration: none;
  font-weight: 500;
  transition: color 0.15s ease;
}
.nav-links a:hover, .nav-links a.active {
  color: var(--color-accent);
}
.btn-nav-primary {
  background: var(--color-accent);
  color: #ffffff !important;
  padding: 6px 14px;
  border-radius: 6px;
  font-weight: 600;
}
.btn-nav-primary:hover {
  background: var(--color-accent-hover);
  text-decoration: none;
}

/* Layout Container */
.site-container {
  max-width: 1280px;
  margin: 0 auto;
  padding: 32px 24px;
}

/* Hero Section */
.hero {
  text-align: center;
  padding: 48px 16px 36px;
  max-width: 900px;
  margin: 0 auto;
}
.hero h1 {
  font-size: 3rem;
  font-weight: 800;
  line-height: 1.15;
  margin: 0 0 16px;
  letter-spacing: -0.03em;
  background: linear-gradient(135deg, var(--text-primary) 30%, var(--color-accent) 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
}
.hero p.tagline {
  font-size: 1.25rem;
  color: var(--text-secondary);
  line-height: 1.5;
  margin: 0 auto 32px;
}

/* Quick Install Card / Tabs */
.install-tabs {
  background: var(--card-bg);
  border: 1px solid var(--border-default);
  border-radius: 12px;
  padding: 20px;
  max-width: 800px;
  margin: 0 auto 48px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.05);
}
.tab-buttons {
  display: flex;
  gap: 8px;
  border-bottom: 1px solid var(--border-muted);
  padding-bottom: 12px;
  margin-bottom: 16px;
  overflow-x: auto;
}
.tab-btn {
  background: transparent;
  border: none;
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--text-secondary);
  padding: 6px 12px;
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.15s ease;
  white-space: nowrap;
}
.tab-btn:hover {
  color: var(--text-primary);
  background: var(--bg-tertiary);
}
.tab-btn.active {
  color: var(--color-accent);
  background: var(--color-accent-subtle);
}
.tab-pane {
  display: none;
  text-align: left;
}
.tab-pane.active {
  display: block;
}
.install-snippet {
  position: relative;
  background: var(--code-bg);
  border: 1px solid var(--border-muted);
  border-radius: 8px;
  padding: 14px 16px;
  font-family: var(--font-mono);
  font-size: 0.9rem;
  overflow-x: auto;
  color: var(--text-primary);
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.install-snippet code {
  user-select: all;
}
.btn-copy {
  background: var(--bg-tertiary);
  border: 1px solid var(--border-default);
  color: var(--text-secondary);
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 0.75rem;
  font-weight: 600;
  cursor: pointer;
}
.btn-copy:hover {
  color: var(--text-primary);
  border-color: var(--color-accent);
}

/* Documentation Cards Grid */
.docs-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 20px;
  margin-bottom: 60px;
}
.doc-card {
  background: var(--card-bg);
  border: 1px solid var(--card-border);
  border-radius: 10px;
  padding: 24px;
  transition: transform 0.15s ease, box-shadow 0.15s ease, border-color 0.15s ease;
  display: flex;
  flex-direction: column;
  justify-content: space-between;
  text-decoration: none !important;
}
.doc-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.08);
  border-color: var(--color-accent);
}
.doc-card-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 8px;
}
.doc-card-icon {
  font-size: 1.5rem;
}
.doc-card h3 {
  margin: 0;
  font-size: 1.15rem;
  font-weight: 600;
  color: var(--text-primary);
}
.doc-card p {
  color: var(--text-secondary);
  font-size: 0.9rem;
  margin: 0 0 16px;
  line-height: 1.5;
}
.doc-card-link {
  font-size: 0.85rem;
  font-weight: 600;
  color: var(--color-accent);
  display: flex;
  align-items: center;
  gap: 4px;
}

/* Documentation Page Layout */
.doc-layout {
  display: flex;
  gap: 48px;
  max-width: 1280px;
  margin: 0 auto;
  padding: 32px 24px;
}
aside.doc-sidebar {
  width: var(--sidebar-width);
  flex-shrink: 0;
  position: sticky;
  top: 80px;
  height: calc(100vh - 100px);
  overflow-y: auto;
  padding-right: 16px;
  border-right: 1px solid var(--border-default);
}
.sidebar-section-title {
  font-size: 0.75rem;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  font-weight: 700;
  color: var(--text-muted);
  margin: 16px 0 8px;
}
.sidebar-nav {
  list-style: none;
  padding: 0;
  margin: 0;
}
.sidebar-nav li {
  margin-bottom: 4px;
}
.sidebar-nav a {
  display: block;
  padding: 6px 10px;
  font-size: 0.9rem;
  color: var(--text-secondary);
  border-radius: 6px;
  text-decoration: none;
}
.sidebar-nav a:hover {
  color: var(--text-primary);
  background: var(--bg-secondary);
}
.sidebar-nav a.active {
  color: var(--color-accent);
  background: var(--color-accent-subtle);
  font-weight: 600;
}
main.doc-content {
  flex-grow: 1;
  min-width: 0;
  max-width: 880px;
}

/* Markdown Content Elements */
.markdown-body {
  line-height: 1.7;
}
.markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 {
  color: var(--text-primary);
  font-weight: 700;
  line-height: 1.25;
  margin-top: 1.75em;
  margin-bottom: 0.6em;
}
.markdown-body h1 {
  font-size: 2.25rem;
  border-bottom: 1px solid var(--border-default);
  padding-bottom: 0.4em;
  margin-top: 0;
}
.markdown-body h2 {
  font-size: 1.6rem;
  border-bottom: 1px solid var(--border-muted);
  padding-bottom: 0.3em;
}
.markdown-body h3 { font-size: 1.3rem; }
.markdown-body h4 { font-size: 1.1rem; }
.markdown-body p { margin: 1em 0; }
.markdown-body hr {
  border: 0;
  border-top: 1px solid var(--border-default);
  margin: 2.5em 0;
}
.markdown-body blockquote {
  margin: 1.2em 0;
  padding: 8px 18px;
  border-left: 4px solid var(--color-accent);
  background: var(--bg-secondary);
  border-radius: 0 6px 6px 0;
  color: var(--text-secondary);
}
.markdown-body pre {
  background: var(--code-bg);
  border: 1px solid var(--border-default);
  border-radius: 8px;
  padding: 16px;
  overflow-x: auto;
  font-family: var(--font-mono);
  font-size: 0.88rem;
  line-height: 1.5;
}
.markdown-body code {
  font-family: var(--font-mono);
  font-size: 0.88em;
  background: var(--code-bg);
  padding: 2px 6px;
  border-radius: 4px;
  border: 1px solid var(--border-muted);
}
.markdown-body pre code {
  background: transparent;
  padding: 0;
  border: none;
}
.markdown-body table {
  width: 100%;
  border-collapse: collapse;
  margin: 1.5em 0;
  font-size: 0.92rem;
}
.markdown-body th, .markdown-body td {
  border: 1px solid var(--border-default);
  padding: 10px 14px;
  text-align: left;
}
.markdown-body th {
  background: var(--bg-secondary);
  font-weight: 600;
}
.markdown-body tr:nth-child(even) {
  background: var(--bg-secondary);
}
.markdown-body ul, .markdown-body ol {
  padding-left: 2em;
  margin: 1em 0;
}
.markdown-body li {
  margin: 0.35em 0;
}

/* Mermaid Diagrams */
.mermaid-container {
  background: var(--bg-secondary);
  border: 1px solid var(--border-default);
  border-radius: 8px;
  padding: 20px;
  margin: 1.5em 0;
  overflow-x: auto;
  text-align: center;
}

/* Footer */
footer.site-footer {
  border-top: 1px solid var(--border-default);
  padding: 40px 24px;
  text-align: center;
  color: var(--text-muted);
  font-size: 0.9rem;
  margin-top: 80px;
}
footer.site-footer a { color: var(--text-secondary); }
footer.site-footer a:hover { color: var(--color-accent); }

/* Responsive Adjustments */
@media (max-width: 900px) {
  .doc-layout { flex-direction: column; }
  aside.doc-sidebar { width: 100%; height: auto; position: static; border-right: none; border-bottom: 1px solid var(--border-default); padding-bottom: 24px; }
  .hero h1 { font-size: 2.2rem; }
}
"""

SITE_JS = """
function switchTab(evt, tabId) {
  document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
  document.querySelectorAll('.tab-pane').forEach(pane => pane.classList.remove('active'));
  evt.currentTarget.classList.add('active');
  const target = document.getElementById(tabId);
  if (target) target.classList.add('active');
}

function copySnippet(btn, codeId) {
  const el = document.getElementById(codeId);
  if (!el) return;
  const text = el.innerText || el.textContent;
  navigator.clipboard.writeText(text.trim()).then(() => {
    const originalText = btn.innerText;
    btn.innerText = 'Copied!';
    setTimeout(() => { btn.innerText = originalText; }, 2000);
  });
}
"""


def slugify(text: str) -> str:
    """Generate anchor id from heading text."""
    s = text.lower().strip()
    s = re.sub(r"[^\w\s-]", "", s)
    s = re.sub(r"[\s_]+", "-", s)
    return s.strip("-")


def render_markdown_to_html(md_text: str, root_prefix: str = "./") -> str:
    """
    Robust pure-python Markdown to HTML renderer for documentation.
    Handles headings with anchor links, code blocks (including mermaid), tables,
    blockquotes, lists, checklists, bold, italics, inline code, and link rewriting.
    """
    lines = md_text.splitlines()
    out = []
    i = 0
    in_code_block = False
    code_lang = ""
    code_lines = []
    in_table = False
    table_headers = []
    table_alignments = []
    table_rows = []
    in_list = False
    list_type = None

    def close_table():
        nonlocal in_table, table_headers, table_alignments, table_rows
        if not in_table:
            return
        tbl = ["<table>", "<thead>", "<tr>"]
        for j, h in enumerate(table_headers):
            align = table_alignments[j] if j < len(table_alignments) else "left"
            align_attr = f' align="{align}"' if align != "left" else ""
            tbl.append(f"<th{align_attr}>{format_inline(h, root_prefix)}</th>")
        tbl.extend(["</tr>", "</thead>", "<tbody>"])
        for row in table_rows:
            tbl.append("<tr>")
            for j, cell in enumerate(row):
                align = table_alignments[j] if j < len(table_alignments) else "left"
                align_attr = f' align="{align}"' if align != "left" else ""
                tbl.append(f"<td{align_attr}>{format_inline(cell, root_prefix)}</td>")
            tbl.append("</tr>")
        tbl.extend(["</tbody>", "</table>"])
        out.append("\n".join(tbl))
        in_table = False
        table_headers = []
        table_alignments = []
        table_rows = []

    def close_list():
        nonlocal in_list, list_type
        if in_list:
            out.append(f"</{list_type}>")
            in_list = False
            list_type = None

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Fenced code blocks
        if stripped.startswith("```"):
            if in_code_block:
                close_table()
                code_text = html.escape("\n".join(code_lines))
                if code_lang == "mermaid":
                    out.append(f'<div class="mermaid-container"><pre class="mermaid">{code_text}</pre></div>')
                else:
                    lang_class = f' class="language-{code_lang}"' if code_lang else ""
                    out.append(f'<pre><code{lang_class}>{code_text}</code></pre>')
                in_code_block = False
                code_lang = ""
                code_lines = []
            else:
                close_list()
                close_table()
                in_code_block = True
                code_lang = stripped[3:].strip()
                code_lines = []
            i += 1
            continue

        if in_code_block:
            code_lines.append(line)
            i += 1
            continue

        # Empty lines
        if not stripped:
            close_table()
            close_list()
            i += 1
            continue

        # Horizontal rules
        if re.match(r"^(\-{3,}|\*{3,}|_{3,})$", stripped):
            close_table()
            close_list()
            out.append("<hr>")
            i += 1
            continue

        # Tables: header row followed by delimiter |---|---|
        if "|" in line and i + 1 < len(lines) and re.match(r"^\s*\|?(\s*:?-+:?\s*\|)+(\s*:?-+:?\s*)?$", lines[i + 1]):
            close_list()
            close_table()
            raw_headers = [c.strip() for c in line.strip().strip("|").split("|")]
            delim_line = lines[i + 1].strip().strip("|")
            raw_delims = [c.strip() for c in delim_line.split("|")]
            table_headers = raw_headers
            table_alignments = []
            for d in raw_delims:
                if d.startswith(":") and d.endswith(":"):
                    table_alignments.append("center")
                elif d.endswith(":"):
                    table_alignments.append("right")
                else:
                    table_alignments.append("left")
            table_rows = []
            in_table = True
            i += 2
            continue

        if in_table:
            if "|" in line:
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                table_rows.append(cells)
                i += 1
                continue
            else:
                close_table()

        # Headings
        heading_match = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading_match:
            close_list()
            close_table()
            level = len(heading_match.group(1))
            heading_content = heading_match.group(2).strip()
            anchor = slugify(heading_content)
            formatted = format_inline(heading_content, root_prefix)
            out.append(f'<h{level} id="{anchor}"><a href="#{anchor}" class="anchor-link">{formatted}</a></h{level}>')
            i += 1
            continue

        # Blockquotes
        if line.startswith(">"):
            close_list()
            close_table()
            quote_lines = []
            while i < len(lines) and lines[i].startswith(">"):
                quote_lines.append(lines[i][1:].strip())
                i += 1
            quote_text = "<br>".join([format_inline(ql, root_prefix) for ql in quote_lines if ql])
            out.append(f"<blockquote><p>{quote_text}</p></blockquote>")
            continue

        # Unordered Lists
        ul_match = re.match(r"^(\s*)[-*+]\s+(.*)$", line)
        if ul_match:
            close_table()
            if not in_list or list_type != "ul":
                close_list()
                out.append("<ul>")
                in_list = True
                list_type = "ul"
            item_text = ul_match.group(2)
            # Checklists
            if item_text.startswith("[x] ") or item_text.startswith("[X] "):
                item_html = '<input type="checkbox" checked disabled> ' + format_inline(item_text[4:], root_prefix)
            elif item_text.startswith("[ ] "):
                item_html = '<input type="checkbox" disabled> ' + format_inline(item_text[4:], root_prefix)
            else:
                item_html = format_inline(item_text, root_prefix)
            out.append(f"<li>{item_html}</li>")
            i += 1
            continue

        # Ordered Lists
        ol_match = re.match(r"^(\s*)\d+\.\s+(.*)$", line)
        if ol_match:
            close_table()
            if not in_list or list_type != "ol":
                close_list()
                out.append("<ol>")
                in_list = True
                list_type = "ol"
            item_text = ol_match.group(2)
            out.append(f"<li>{format_inline(item_text, root_prefix)}</li>")
            i += 1
            continue

        # Regular Paragraph
        close_list()
        close_table()
        p_lines = [line]
        i += 1
        while i < len(lines):
            next_l = lines[i]
            if not next_l.strip() or next_l.startswith("#") or next_l.startswith("```") or next_l.startswith(">") or next_l.startswith("-") or next_l.startswith("*") or re.match(r"^\d+\.", next_l):
                break
            p_lines.append(next_l)
            i += 1
        paragraph_text = " ".join(p_lines)
        out.append(f"<p>{format_inline(paragraph_text, root_prefix)}</p>")

    close_list()
    close_table()
    return "\n".join(out)


def format_inline(text: str, root_prefix: str = "./") -> str:
    """Format inline markdown elements: links, code spans, bold, italic, images."""
    # Escape HTML special chars first, except if already generated
    # We token-protect code spans first to prevent sub-parsing inside code
    code_spans = []

    def save_code(m):
        code_spans.append(m.group(1))
        return f"\x00CODE_{len(code_spans) - 1}\x00"

    text = re.sub(r"`([^`]+)`", save_code, text)
    text = html.escape(text, quote=False)

    # Images ![alt](url)
    text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r'<img src="\2" alt="\1">', text)

    # Links [text](url) - Rewriting .md links to .html for docs navigation
    def link_repl(m):
        label = m.group(1)
        url = m.group(2)
        # Rewrite relative .md links to .html
        if url.endswith(".md"):
            url = url[:-3] + ".html"
        elif ".md#" in url:
            url = url.replace(".md#", ".html#")
        return f'<a href="{url}">{label}</a>'

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link_repl, text)

    # Bold and Italic
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"__([^_]+)__", r"<strong>\1</strong>", text)
    text = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", text)
    text = re.sub(r"_([^_]+)_", r"<em>\1</em>", text)

    # Restore code spans
    for idx, code_content in enumerate(code_spans):
        escaped_code = html.escape(code_content)
        text = text.replace(f"\x00CODE_{idx}\x00", f"<code>{escaped_code}</code>")

    return text


def build_page_html(title: str, content_html: str, root_prefix: str = "./", active_slug: str = None) -> str:
    """Wrap content in complete responsive HTML template with header, sidebar, and footer."""
    nav_links_html = f"""
      <a href="{root_prefix}index.html" class="{'active' if active_slug == 'home' else ''}">Overview</a>
      <a href="{root_prefix}docs/architecture.html" class="{'active' if active_slug and active_slug != 'home' and active_slug != 'apt' else ''}">Documentation</a>
      <a href="{root_prefix}apt/index.html" class="{'active' if active_slug == 'apt' else ''}">APT Repository</a>
      <a href="https://github.com/axiomantic/rhizo" target="_blank" rel="noopener">GitHub</a>
      <a href="{root_prefix}#install" class="btn-nav-primary">Get Started</a>
    """

    sidebar_items_html = ""
    if active_slug and active_slug != "home" and active_slug != "apt":
        items = []
        for doc in DOCS_MANIFEST:
            is_active = doc["slug"] == active_slug
            active_class = ' class="active"' if is_active else ""
            href = f"{root_prefix}docs/{doc['slug']}.html"
            items.append(f'<li><a href="{href}"{active_class}>{doc["icon"]} {doc["title"]}</a></li>')
        sidebar_items_html = f"""
        <aside class="doc-sidebar">
          <div class="sidebar-section-title">Documentation</div>
          <ul class="sidebar-nav">
            <li><a href="{root_prefix}index.html">🏠 Home & Portal</a></li>
            <li><a href="{root_prefix}apt/index.html">📦 APT Repository</a></li>
          </ul>
          <div class="sidebar-section-title">Specifications & Guides</div>
          <ul class="sidebar-nav">
            {''.join(items)}
          </ul>
          <div class="sidebar-section-title">External Links</div>
          <ul class="sidebar-nav">
            <li><a href="https://github.com/axiomantic/rhizo" target="_blank" rel="noopener">GitHub Repository ↗</a></li>
            <li><a href="https://www.npmjs.com/package/@axiomantic/rhizo" target="_blank" rel="noopener">npm Package ↗</a></li>
          </ul>
        </aside>
        """

    has_sidebar = bool(sidebar_items_html)
    main_layout_start = '<div class="doc-layout">' if has_sidebar else '<div class="site-container">'
    main_layout_end = '</div>'

    main_tag_start = '<main class="doc-content markdown-body">' if has_sidebar else '<div class="markdown-body">'
    main_tag_end = '</main>' if has_sidebar else '</div>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)} — Rhizo</title>
  <meta name="description" content="Rhizo: High-performance, single-binary inter-assistant communication bus, monotonic work queues, and distributed mutexes over Redis.">
  <style>{SITE_CSS}</style>
  <script>{SITE_JS}</script>
  <script type="module">
    import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs';
    mermaid.initialize({{ startOnLoad: true, theme: 'neutral' }});
  </script>
</head>
<body>
  <header class="site-header">
    <div class="header-inner">
      <a href="{root_prefix}index.html" class="brand">
        <span class="logo-badge">rhizo</span>
        <span>Axiomantic Rhizo</span>
      </a>
      <nav class="nav-links">
        {nav_links_html}
      </nav>
    </div>
  </header>

  {main_layout_start}
    {sidebar_items_html}
    {main_tag_start}
      {content_html}
    {main_tag_end}
  {main_layout_end}

  <footer class="site-footer">
    <p>Axiomantic Rhizo — Apache-2.0 Licensed. Designed for multi-agent coding swarms.</p>
    <p>
      <a href="https://github.com/axiomantic/rhizo">GitHub</a> &bull;
      <a href="https://www.npmjs.com/package/@axiomantic/rhizo">npm</a> &bull;
      <a href="{root_prefix}apt/index.html">APT Repository</a> &bull;
      <a href="{root_prefix}docs/cli_reference.html">CLI Reference</a> &bull;
      <a href="{root_prefix}docs/architecture.html">Architecture</a>
    </p>
  </footer>
</body>
</html>
"""


def generate_portal_home(readme_path: Path, root_prefix: str = "./") -> str:
    """Generate the root portal index.html with hero, package manager tabs, docs cards, and README."""
    readme_text = readme_path.read_text(encoding="utf-8") if readme_path.exists() else "# Rhizo\n\nInter-Assistant Redis Bus."
    readme_html = render_markdown_to_html(readme_text, root_prefix=root_prefix)

    # Documentation Cards HTML
    cards_html = []
    for doc in DOCS_MANIFEST:
        cards_html.append(f"""
        <a href="{root_prefix}docs/{doc['slug']}.html" class="doc-card">
          <div>
            <div class="doc-card-header">
              <span class="doc-card-icon">{doc['icon']}</span>
              <h3>{doc['title']}</h3>
            </div>
            <p>{doc['description']}</p>
          </div>
          <div class="doc-card-link">Read Guide &rarr;</div>
        </a>
        """)

    hero_and_install_html = f"""
    <section class="hero">
      <h1>The Inter-Assistant Redis Bus</h1>
      <p class="tagline">
        Sub-millisecond inter-agent communication, distributed fencing mutexes, monotonic work queues, and continuous ear listeners for multi-agent coding swarms.
      </p>

      <div class="install-tabs" id="install">
        <div class="tab-buttons">
          <button class="tab-btn active" onclick="switchTab(event, 'tab-npm')">📦 npm (Global)</button>
          <button class="tab-btn" onclick="switchTab(event, 'tab-brew')">🍺 Homebrew</button>
          <button class="tab-btn" onclick="switchTab(event, 'tab-apt')">🐧 Debian / Ubuntu (APT)</button>
          <button class="tab-btn" onclick="switchTab(event, 'tab-scoop')">🪟 Windows (Scoop)</button>
          <button class="tab-btn" onclick="switchTab(event, 'tab-curl')">⚡ One-Line Curl</button>
        </div>

        <div class="tab-pane active" id="tab-npm">
          <div class="install-snippet">
            <code id="code-npm">npm install -g @axiomantic/rhizo</code>
            <button class="btn-copy" onclick="copySnippet(this, 'code-npm')">Copy</button>
          </div>
          <p style="font-size:0.85rem; color:var(--text-muted); margin: 8px 0 0;">Zero-compilation fat binary package with pre-bundled native Nim binaries for macOS, Linux, and Windows.</p>
        </div>

        <div class="tab-pane" id="tab-brew">
          <div class="install-snippet">
            <code id="code-brew">brew install axiomantic/tap/rhizo</code>
            <button class="btn-copy" onclick="copySnippet(this, 'code-brew')">Copy</button>
          </div>
          <p style="font-size:0.85rem; color:var(--text-muted); margin: 8px 0 0;">Official Homebrew formula with binary bottles for Apple Silicon and Intel macOS.</p>
        </div>

        <div class="tab-pane" id="tab-apt">
          <div class="install-snippet">
            <code id="code-apt">echo "deb [trusted=yes] https://axiomantic.github.io/rhizo/apt/ ./" | sudo tee /etc/apt/sources.list.d/rhizo.list &amp;&amp; sudo apt-get update &amp;&amp; sudo apt-get install -y rhizo</code>
            <button class="btn-copy" onclick="copySnippet(this, 'code-apt')">Copy</button>
          </div>
          <p style="font-size:0.85rem; color:var(--text-muted); margin: 8px 0 0;">Official Debian/Ubuntu APT repository for amd64 and arm64 architectures. <a href="{root_prefix}apt/index.html">Browse APT Repo &rarr;</a></p>
        </div>

        <div class="tab-pane" id="tab-scoop">
          <div class="install-snippet">
            <code id="code-scoop">scoop bucket add axiomantic https://github.com/axiomantic/scoop-bucket &amp;&amp; scoop install rhizo</code>
            <button class="btn-copy" onclick="copySnippet(this, 'code-scoop')">Copy</button>
          </div>
          <p style="font-size:0.85rem; color:var(--text-muted); margin: 8px 0 0;">Windows package management via Scoop.</p>
        </div>

        <div class="tab-pane" id="tab-curl">
          <div class="install-snippet">
            <code id="code-curl">curl -fsSL https://raw.githubusercontent.com/axiomantic/rhizo/main/scripts/install.sh | bash</code>
            <button class="btn-copy" onclick="copySnippet(this, 'code-curl')">Copy</button>
          </div>
          <p style="font-size:0.85rem; color:var(--text-muted); margin: 8px 0 0;">Universal standalone POSIX shell installer.</p>
        </div>
      </div>
    </section>

    <h2 style="font-size:1.75rem; font-weight:700; border-bottom:1px solid var(--border-default); padding-bottom:8px; margin: 40px 0 24px;">Architecture &amp; Guides</h2>
    <div class="docs-grid">
      {''.join(cards_html)}
    </div>

    <h2 style="font-size:1.75rem; font-weight:700; border-bottom:1px solid var(--border-default); padding-bottom:8px; margin: 48px 0 24px;">Project Documentation</h2>
    <div class="readme-content">
      {readme_html}
    </div>
    """

    return build_page_html(
        title="Rhizo — Inter-Assistant Redis Bus & Swarm Coordination",
        content_html=hero_and_install_html,
        root_prefix=root_prefix,
        active_slug="home",
    )


def generate_docs_pages(repo_root: Path, out_dir: Path, root_prefix: str = "../") -> list:
    """Render all markdown documents in docs/ to out_dir/docs/*.html."""
    docs_out = out_dir / "docs"
    docs_out.mkdir(parents=True, exist_ok=True)
    generated = []

    for item in DOCS_MANIFEST:
        src_path = repo_root / item["source"]
        if not src_path.exists():
            print(f"Warning: doc source {src_path} does not exist, skipping.")
            continue
        md_text = src_path.read_text(encoding="utf-8")
        body_html = render_markdown_to_html(md_text, root_prefix=root_prefix)
        page_html = build_page_html(
            title=item["title"],
            content_html=body_html,
            root_prefix=root_prefix,
            active_slug=item["slug"],
        )
        dest_file = docs_out / f"{item['slug']}.html"
        dest_file.write_text(page_html, encoding="utf-8")
        generated.append(dest_file)
        print(f"Rendered doc: {dest_file.relative_to(out_dir)}")

    return generated
