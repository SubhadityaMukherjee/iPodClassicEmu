#!/bin/bash
# Build the MkDocs documentation site into ./site.
# CI (.github/workflows/docs.yml) runs the same script before deploying
# to GitHub Pages, so local output === deployed output.
set -euo pipefail
cd "$(dirname "$0")/.."

# The contributor cheat-sheet lives at the repo root; copy it in so the
# docs site can serve it without moving the file agents expect to find.
cp AGENTS.md docs/AGENTS.md

uvx --from mkdocs-material mkdocs build --strict --site-dir site
echo "site built → $(pwd)/site/index.html"
