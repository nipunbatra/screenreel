#!/bin/bash
# Publish a release: tag v$VERSION and create the GitHub release with the
# notarized DMG and the matching CHANGELOG.md section as notes.
#
# Usage: Scripts/release.sh [--dry-run]
#
# Preconditions (all checked, all fatal):
#   - VERSION has a matching "## <VERSION>" section in CHANGELOG.md
#   - the working tree is clean and on main
#   - dist/<APP_NAME>-<VERSION>.dmg exists and is stapled (Scripts/notarize.sh)
#   - `gh auth status` succeeds
#   - the tag v<VERSION> does not exist yet
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="${APP_NAME:-Screen Reel}"
ARTIFACT_NAME="${ARTIFACT_NAME:-screenreel}"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
DMG="dist/${ARTIFACT_NAME}-${VERSION}.dmg"
LATEST_ALIAS="dist/${ARTIFACT_NAME}.dmg"   # stable, space-free download name
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v gh >/dev/null || fail "gh CLI not installed (brew install gh)"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || fail "gh is not authenticated: run 'gh auth login -h github.com' (do not create a separate token)"

[ -f "$DMG" ] || fail "$DMG not found — run Scripts/make-dmg.sh then Scripts/notarize.sh"
xcrun stapler validate "$DMG" >/dev/null 2>&1 \
    || fail "$DMG has no stapled notarization ticket — run Scripts/notarize.sh"

# The DMG must have been built from this exact VERSION.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT" -quiet || true' EXIT
BUNDLED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT/${APP_NAME}.app/Contents/Info.plist")
codesign --verify --deep --strict "$MOUNT/${APP_NAME}.app"
spctl --assess --type execute "$MOUNT/${APP_NAME}.app"
hdiutil detach "$MOUNT" -quiet
trap - EXIT
[ "$BUNDLED" = "$VERSION" ] || fail "DMG contains version $BUNDLED but VERSION is $VERSION"

[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = "main" ] || fail "releases are cut from main (currently on $BRANCH)"
git fetch --tags origin >/dev/null 2>&1 || fail "cannot reach origin"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "tag $TAG already exists"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && fail "tag $TAG already exists on origin"

# Release notes: the "## <VERSION>" section of CHANGELOG.md up to the next "## ".
NOTES="$(mktemp -t release-notes).md"
awk -v version="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## " version) == 1) { found = 1; next } }
    found { print }
' CHANGELOG.md | sed -e '1{/^$/d;}' > "$NOTES"
[ -s "$NOTES" ] || fail "CHANGELOG.md has no '## $VERSION' section"
grep -qi "unreleased" "$NOTES" && fail "CHANGELOG.md section for $VERSION still says 'Unreleased'"
grep -qi "unreleased" <(grep "^## $VERSION" CHANGELOG.md) && fail "CHANGELOG.md heading for $VERSION still says 'Unreleased'"

cp -f "$DMG" "$LATEST_ALIAS"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")") > "$DMG.sha256.txt"

echo "Release $TAG of $APP_NAME"
echo "  DMG:   $DMG ($(du -h "$DMG" | cut -f1))"
echo "  Notes: $NOTES"
echo "-----"
cat "$NOTES"
echo "-----"

if [ "$DRY_RUN" = "1" ]; then
    echo "--dry-run: not tagging or publishing"
    exit 0
fi

git tag -a "$TAG" -m "$APP_NAME $VERSION"
git push origin "$TAG"
gh release create "$TAG" \
    "$DMG" "$LATEST_ALIAS" "$DMG.sha256.txt" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$NOTES" \
    --verify-tag
echo "Published: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
echo "The in-app update check will now offer $VERSION to older builds."
