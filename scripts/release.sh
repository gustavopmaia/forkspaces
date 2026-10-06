#!/bin/zsh
# Usage: ./scripts/release.sh 0.2.0
# Local release flow: set VERSION, build and verify Forkspaces.dmg, then (after you confirm)
# commit, tag v<version>, push and publish a GitHub Release with the dmg and its checksum.
# Needs a clean git tree and the GitHub CLI (`gh auth login`). Honors SIGN_IDENTITY like build-release.sh.
set -eu
cd "${0:A:h:h}"
VERSION="${1:?usage: ./scripts/release.sh <major.minor.patch>}"
TAG="v$VERSION"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Version must be MAJOR.MINOR.PATCH"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit or stash your changes first."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { print -u2 "Tag $TAG already exists."; exit 1; }
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { print -u2 "Install the GitHub CLI and run: gh auth login"; exit 1; }

print "$VERSION" > VERSION
trap 'git checkout -q -- VERSION' EXIT   # undone unless the release is committed below
BUILD_NUMBER="$(( $(git rev-list --count HEAD 2>/dev/null || print 0) + 1 ))" ./scripts/build-release.sh
(cd build && shasum -a 256 Forkspaces.dmg > Forkspaces.dmg.sha256)

print "\nForkspaces $VERSION is built:"
print "  build/Forkspaces.dmg  $(du -h build/Forkspaces.dmg | cut -f1)"
print "  sha256 $(cut -d' ' -f1 build/Forkspaces.dmg.sha256)"
print "Test it now if you like (open build/Forkspaces.dmg)."
read -q "?Commit, tag $TAG, push and publish the GitHub Release? [y/N] " || { print "\nNothing was committed or published."; exit 0; }
print

git diff --quiet VERSION || git commit -q -m "Release $VERSION" VERSION
trap - EXIT
git tag -a "$TAG" -m "Forkspaces $VERSION"
git push -q origin HEAD "$TAG"
gh release create "$TAG" build/Forkspaces.dmg build/Forkspaces.dmg.sha256 --title "Forkspaces $VERSION" --generate-notes --verify-tag
