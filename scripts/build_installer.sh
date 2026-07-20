#!/usr/bin/env bash
# Compile the GUI installer "Install 轻语.app" at the repo root from
# scripts/gui_install.applescript.
#
# osacompile ad-hoc-signs the applet as it writes it. In an iCloud/Dropbox-synced
# folder the file-provider re-tags the bundle with com.apple.FinderInfo and that
# signing step fails ("resource fork ... not allowed"), so we compile in a temp dir
# (outside sync) and copy the finished app into place.
set -euo pipefail
cd "$(dirname "$0")/.."

TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

osacompile -o "$TMPDIR_BUILD/Install 轻语.app" scripts/gui_install.applescript
rm -rf "Install 轻语.app"
cp -R "$TMPDIR_BUILD/Install 轻语.app" "Install 轻语.app"
xattr -cr "Install 轻语.app" 2>/dev/null || true

echo "Built: Install 轻语.app  (double-click it to run the guided setup)"
