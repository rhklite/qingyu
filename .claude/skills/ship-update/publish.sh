#!/usr/bin/env bash
# Cuts a 轻语 update and puts it where Sparkle will find it.
#
# The whole point of this script is that the three things which must agree — the version
# inside the app, the DMG, and the appcast the updater reads — are produced in one pass
# and then checked against each other and against the live feed. Doing any of them by
# hand is how you ship a release nobody is offered, or one everybody is offered and
# nobody can download.
#
# Usage:
#   .claude/skills/ship-update/publish.sh                    # build + verify locally, touch nothing
#   .claude/skills/ship-update/publish.sh --publish --notes "…what changed…"
#   .claude/skills/ship-update/publish.sh --version 0.4.0 --publish --notes "…"
#   .claude/skills/ship-update/publish.sh --reuse-build --publish --notes "…"
#
# --reuse-build skips the rebuild and verifies (or publishes) whatever the last run left
# in dist/. Useful when the build succeeded and only the upload failed, and it is how
# changes to this script are tested without paying for a universal build each time.
#
# Without --publish nothing leaves this machine: Resources/Info.plist is restored on the
# way out, no commit is made, no release is created. That is the mode to use while
# testing changes to this script.
set -euo pipefail

cd "$(dirname "$0")/../../.."
ROOT="$(pwd)"
PLIST="$ROOT/Resources/Info.plist"
DIST="$ROOT/dist"
REPO="rhklite/qingyu"
FEED="https://github.com/$REPO/releases/latest/download/appcast.xml"

VERSION=""
NOTES=""
PUBLISH=0
REUSE=0

need() { [[ -n "${2:-}" && "${2:-}" != --* ]] || { echo "$1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) need "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
        --notes)   need "$1" "${2:-}"; NOTES="$2";   shift 2 ;;
        --publish) PUBLISH=1;                        shift ;;
        --reuse-build) REUSE=1;                      shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

plist_get() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$PLIST"; }

# ---------------------------------------------------------------- preflight
step "Preflight"

[[ -x "$ROOT/third_party/Sparkle/bin/generate_appcast" ]] ||
    die "third_party/Sparkle/bin/generate_appcast is missing — the appcast cannot be signed."
[[ -f "$ROOT/Resources/AppIcon.icns" ]] ||
    die "Resources/AppIcon.icns is missing — makedmg.sh refuses to build without it."
ls -d "$ROOT"/third_party/whisper.cpp/build-* >/dev/null 2>&1 ||
    die "whisper.cpp is not built. Run scripts/build_whisper.sh first."

# Sparkle signs with a private key that lives only in the login Keychain. Without it
# generate_appcast emits an unsigned feed and every install rejects the update, so this
# is worth failing on before a five-minute build rather than after it.
security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 ||
    die "No Sparkle EdDSA private key in the login Keychain — updates could not be signed."

if (( PUBLISH )); then
    command -v gh >/dev/null || die "gh is not installed — cannot create the GitHub release."
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
    [[ -n "$NOTES" ]] ||
        die "--publish needs --notes: the text becomes what users read in the update window."

    # The DMG is built from the working tree, but the tag names a commit. If anything
    # other than the version bump is uncommitted, the release would ship code that the
    # tag does not contain — the kind of drift nobody notices until they try to
    # reproduce a build months later.
    DIRTY="$(git status --porcelain -- . ':(exclude)Resources/Info.plist')"
    [[ -z "$DIRTY" ]] || die "Working tree is dirty. Commit or stash first:
$DIRTY"
fi
echo "ok"

# ------------------------------------------------------------- version bump
CURRENT="$(plist_get CFBundleShortVersionString)"
BUILD_NUM="$(plist_get CFBundleVersion)"

if [[ -z "$VERSION" ]]; then
    # Default to a patch bump. Sparkle only offers an update whose CFBundleVersion is
    # higher than the running one, so a release that reuses the current version is
    # invisible to exactly the users it is meant to reach.
    IFS=. read -r MAJ MIN PAT <<<"$CURRENT"
    [[ -n "${PAT:-}" ]] || die "Cannot parse '$CURRENT' as X.Y.Z — pass --version explicitly."
    VERSION="$MAJ.$MIN.$((PAT + 1))"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like X.Y.Z, got '$VERSION'."

# The one thing that actually must not be true is that the tag is already published:
# a version equal to the one in Info.plist is normal when resuming a run whose bump was
# committed but whose upload failed. Checked in local mode too, so a pointless build is
# refused before it starts rather than after.
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 ||
        die "Release v$VERSION is already published. Pick a higher --version."
elif (( PUBLISH )); then
    die "gh is not available or not authenticated — cannot check whether v$VERSION exists."
fi

if [[ "$VERSION" == "$CURRENT" ]]; then
    NEW_BUILD="$BUILD_NUM"      # already bumped by an earlier run; leave it alone
else
    NEW_BUILD=$((BUILD_NUM + 1))
fi

# Info.plist is edited in place because makedmg.sh and release.sh both read it. Restore
# it unless the release actually goes out, so a failed or local run leaves no trace.
KEEP_BUMP=0
ORIG_PLIST="$(mktemp)"
cp "$PLIST" "$ORIG_PLIST"
cleanup() {
    (( KEEP_BUMP )) || cp "$ORIG_PLIST" "$PLIST"
    rm -f "$ORIG_PLIST"
}
trap cleanup EXIT

step "Version $CURRENT (build $BUILD_NUM) → $VERSION (build $NEW_BUILD)"
plist_set CFBundleShortVersionString "$VERSION"
plist_set CFBundleVersion "$NEW_BUILD"

# ------------------------------------------------------------------- build
if (( REUSE )); then
    step "Reusing the DMG and appcast already in dist/"
    # Reusing a build is only safe while it still matches the tree it was built from.
    # Publishing a DMG older than a source file is how a "fixed" release ships without
    # the fix in it.
    STALE_DMG="$DIST/Qingyu-$VERSION.dmg"
    if (( PUBLISH )) && [[ -f "$STALE_DMG" ]]; then
        # Info.plist is excluded because this script rewrote it a moment ago; whether
        # the DMG holds the right version is settled below by reading it out of the
        # bundle inside the image, which is the check that can't be fooled by an mtime.
        NEWER="$(find "$ROOT/Sources" "$ROOT/Resources" "$ROOT/scripts" \
                     -type f -newer "$STALE_DMG" \
                     ! -path "$PLIST" -print -quit 2>/dev/null || true)"
        [[ -z "$NEWER" ]] ||
            die "$NEWER is newer than the DMG being reused. Re-run without --reuse-build."
    fi
else
    step "Building the DMG and signing the appcast"
    "$ROOT/scripts/release.sh"
fi

DMG="$DIST/Qingyu-$VERSION.dmg"
APPCAST="$DIST/appcast.xml"
MISSING="release.sh did not produce"
(( REUSE )) && MISSING="--reuse-build was passed but there is no"
[[ -f "$DMG" ]]     || die "$MISSING $DMG."
[[ -f "$APPCAST" ]] || die "$MISSING $APPCAST."

# ------------------------------------------------------------------ verify
step "Verifying the artifacts agree"

# What the appcast claims, read back rather than assumed.
# `|` as the delimiter, not `:` — the tags being matched are `sparkle:version`, and BSD
# sed reads the first `:` inside the pattern as the end of it.
xml_field() { sed -n "s|.*<$1>\(.*\)</$1>.*|\\1|p" "$APPCAST" | head -1; }
FEED_SHORT="$(xml_field 'sparkle:shortVersionString')"
FEED_BUILD="$(xml_field 'sparkle:version')"
FEED_URL="$(sed -n 's|.*<enclosure url="\([^"]*\)".*|\1|p' "$APPCAST" | head -1)"
FEED_LEN="$(sed -n 's|.*length="\([0-9]*\)".*|\1|p' "$APPCAST" | head -1)"

[[ "$FEED_SHORT" == "$VERSION" ]] ||
    die "appcast says shortVersionString $FEED_SHORT, expected $VERSION."
[[ "$FEED_BUILD" == "$NEW_BUILD" ]] ||
    die "appcast says version $FEED_BUILD, expected $NEW_BUILD — Sparkle compares this one."
[[ "$FEED_URL" == "https://github.com/$REPO/releases/download/v$VERSION/Qingyu-$VERSION.dmg" ]] ||
    die "appcast enclosure URL is $FEED_URL, which is not where the release will put the DMG."
grep -q 'edSignature' "$APPCAST" ||
    die "appcast carries no EdDSA signature — every install would reject this update."
[[ "$FEED_LEN" == "$(stat -f %z "$DMG")" ]] ||
    die "appcast length $FEED_LEN does not match the DMG on disk."

# The version inside the DMG, not just the one the build was told to use. Mounting is
# the only way to catch a stale .app being packaged.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
DMG_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/轻语.app/Contents/Info.plist" 2>/dev/null || true)"
DMG_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$MOUNT/轻语.app/Contents/Info.plist" 2>/dev/null || true)"
DMG_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$MOUNT/轻语.app/Contents/Info.plist" 2>/dev/null || true)"
hdiutil detach "$MOUNT" -quiet 2>/dev/null ||
    hdiutil detach "$MOUNT" -force -quiet 2>/dev/null ||
    die "Could not unmount $MOUNT — eject it in Finder before re-running."
rmdir "$MOUNT" 2>/dev/null || true

[[ "$DMG_SHORT" == "$VERSION" ]]   || die "The app inside the DMG reports $DMG_SHORT, not $VERSION."
[[ "$DMG_BUILD" == "$NEW_BUILD" ]] || die "The app inside the DMG is build $DMG_BUILD, not $NEW_BUILD."
[[ "$DMG_FEED" == "$FEED" ]]       || die "The app inside the DMG points at $DMG_FEED, not $FEED."

echo "DMG and appcast both say $VERSION (build $NEW_BUILD), signed, $(du -h "$DMG" | cut -f1)"

if ! (( PUBLISH )); then
    step "Local run — nothing published"
    cat <<EOF
Built and verified:
  $DMG
  $APPCAST

Resources/Info.plist has been restored to $CURRENT (build $BUILD_NUM).
Re-run with --publish --notes "…" to ship it.
EOF
    exit 0
fi

# ----------------------------------------------------------------- publish
# The tag has to name the commit the DMG was built from, so the bump is committed and
# pushed before the release is created. gh cuts the tag from the remote branch.
step "Committing and pushing the version bump"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" != "HEAD" ]] ||
    die "HEAD is detached — check out a branch before releasing."
git add "$PLIST"
if git diff --cached --quiet; then
    echo "Info.plist already at $VERSION in the index; nothing to commit."
else
    git commit -m "Release $VERSION

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
fi
git push origin "$BRANCH"
KEEP_BUMP=1

step "Creating release v$VERSION"
# --latest matters: SUFeedURL points at /releases/latest/download/appcast.xml, so an
# update that is not the latest release is one no running app will ever read.
gh release create "v$VERSION" "$DMG" "$APPCAST" \
    --repo "$REPO" --title "轻语 $VERSION" --notes "$NOTES" --latest

step "Verifying the live feed"
LIVE="$(mktemp)"
for attempt in 1 2 3 4 5; do
    if curl -fsSL --max-time 30 "$FEED" -o "$LIVE" && grep -q "<sparkle:shortVersionString>$VERSION<" "$LIVE"; then
        break
    fi
    [[ $attempt -lt 5 ]] || { rm -f "$LIVE"; die "$FEED still does not serve $VERSION."; }
    sleep 5
done
grep -q 'edSignature' "$LIVE" || { rm -f "$LIVE"; die "The live feed carries no signature."; }
rm -f "$LIVE"

# A one-byte ranged GET rather than HEAD: GitHub redirects release assets to object
# storage, which does not always answer a HEAD the same way it answers a GET.
curl -fsSL --max-time 60 --range 0-0 "$FEED_URL" -o /dev/null ||
    die "The DMG URL in the feed does not resolve: $FEED_URL"

step "Published"
cat <<EOF
v$VERSION is live and the feed serves it.

  Release   https://github.com/$REPO/releases/tag/v$VERSION
  Feed      $FEED

Existing installs are offered it within a day, or immediately from the menu bar's
"Check for Updates…".
EOF
