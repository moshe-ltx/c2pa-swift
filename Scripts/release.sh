#!/bin/bash
# Publishes a Lightricks release of c2pa-swift: an upstream version whose C2PAC.xcframework declares
# MinimumOSVersion 100.
#
# C2PAC is a static framework. Xcode embeds a code-less stub dylib for it, built with the app's
# deployment target as its minos, while the framework's Info.plist keeps upstream's lower
# MinimumOSVersion. App Store Connect rejects that mismatch (ITMS-90208) and only checks that the
# plist value is at least the binary's minos, so 100 always passes. Firebase (firebase-ios-sdk#12439)
# and Braze (braze-swift-sdk 8.2.1) ship the same workaround.
#
# For upstream version X.Y.Z and revision N (default 1), the script:
#   1. Fetches upstream's vX.Y.Z tag and reads the C2PAC url and checksum from its Package.swift.
#   2. Downloads upstream's C2PAC.xcframework.zip and verifies it against that checksum.
#   3. Sets MinimumOSVersion to 100 in every slice's C2PAC.framework/Info.plist and zips it again.
#      The binaries are left untouched.
#   4. Commits a Package.swift that points at the patched zip on top of vX.Y.Z and tags the commit
#      vX.Y.Z-lightricks.N.
#   5. Pushes the tag to the fork, creates a GitHub release for it with the patched zip as an asset,
#      and verifies the published asset's checksum.
#
# The zip is published as a release asset because it's ~400 MB, and GitHub rejects files over
# 100 MB. Depend on the release in Xcode with the fork's URL and the exact version X.Y.Z-lightricks.N.
#
# Usage: Scripts/release.sh [--fork OWNER/REPO] [--dry-run] <upstream version> [<revision>]
#   Scripts/release.sh 0.1.0       # v0.1.0-lightricks.1
#   Scripts/release.sh 0.1.0 2     # v0.1.0-lightricks.2
#
# Options:
#   --fork OWNER/REPO   GitHub repo to publish to (default: $C2PA_FORK_REPO, or the repo of the
#                       first remote that points at a c2pa-swift repo not owned by contentauth).
#   --dry-run           Build the commit, tag and patched zip locally, but push and publish nothing.
#                       The tag is deleted again at the end; the zip stays in the printed directory.
#
# If a run fails after pushing the tag (for example while uploading the release), finish it by hand
# or run again with the next revision.
#
# Requires git, gh (authenticated with push access to the fork), curl, ditto, plutil, zip and perl.
set -euo pipefail

UPSTREAM_REPO="contentauth/c2pa-swift"
UPSTREAM_URL="https://github.com/${UPSTREAM_REPO}.git"
MINIMUM_OS_VERSION="100"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed -E 's/^# ?//' >&2
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

FORK_REPO="${C2PA_FORK_REPO:-}"
DRY_RUN="false"
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fork) FORK_REPO="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[ "${#POSITIONAL[@]}" -ge 1 ] && [ "${#POSITIONAL[@]}" -le 2 ] || usage

VERSION="${POSITIONAL[0]#v}"
REVISION="${POSITIONAL[1]:-1}"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Expected an upstream version like 0.1.0 (got ${VERSION})."
[[ "${REVISION}" =~ ^[1-9][0-9]*$ ]] || fail "Expected a positive revision number (got ${REVISION})."

UPSTREAM_TAG="v${VERSION}"
TAG="v${VERSION}-lightricks.${REVISION}"

for TOOL in git gh curl ditto plutil zip shasum perl; do
  command -v "${TOOL}" > /dev/null || fail "${TOOL} is not installed."
done

REPO_DIR="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "${REPO_DIR}"

if [ -z "${FORK_REPO}" ]; then
  FORK_REPO="$(git remote -v | awk '{print $2}' | sort -u \
    | sed -nE 's#^(https://github\.com/|git@github\.com:)([^/]+/c2pa-swift)(\.git)?/?$#\2#p' \
    | grep -v "^contentauth/" | head -n 1 || true)"
  [ -n "${FORK_REPO}" ] || fail "Couldn't find a fork remote. Pass --fork OWNER/REPO or set C2PA_FORK_REPO."
fi
FORK_URL="https://github.com/${FORK_REPO}.git"
ASSET_URL="https://github.com/${FORK_REPO}/releases/download/${TAG}/C2PAC.xcframework.zip"

echo "Releasing ${TAG} to ${FORK_REPO} from ${UPSTREAM_REPO} ${UPSTREAM_TAG}."
[ "${DRY_RUN}" = "true" ] && echo "Dry run: nothing will be pushed or published."

# Refuse to overwrite anything that already exists, locally or on the fork.
if git rev-parse -q --verify "refs/tags/${TAG}" > /dev/null; then
  fail "Tag ${TAG} already exists locally. Pick another revision, or delete it with: git tag -d ${TAG}"
fi
if [ -n "$(git ls-remote --tags "${FORK_URL}" "refs/tags/${TAG}")" ]; then
  fail "Tag ${TAG} already exists on ${FORK_REPO}. Pick another revision."
fi
if gh release view "${TAG}" -R "${FORK_REPO}" > /dev/null 2>&1; then
  fail "Release ${TAG} already exists on ${FORK_REPO}. Pick another revision."
fi

TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TMP_ROOT%/}/c2pa-swift-release.XXXXXX")"
WORKTREE="${WORK_DIR}/worktree"
TAG_PUSHED="false"
cleanup() {
  git worktree remove --force "${WORKTREE}" > /dev/null 2>&1 || true
  # Keep the local tag only once it's on the fork, so a failed run can simply be run again.
  if [ "${TAG_PUSHED}" != "true" ]; then
    git tag -d "${TAG}" > /dev/null 2>&1 || true
  fi
  if [ "${DRY_RUN}" = "true" ]; then
    echo "Dry run output kept in ${WORK_DIR}."
  else
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

echo "==> Fetching ${UPSTREAM_TAG} from ${UPSTREAM_REPO}"
git fetch -q --no-tags "${UPSTREAM_URL}" "+refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}" \
  || fail "Couldn't fetch ${UPSTREAM_TAG} from ${UPSTREAM_REPO}."

# The C2PAC binary target is the only one with a url, so its url and checksum are the only ones in
# the manifest.
UPSTREAM_MANIFEST="$(git show "${UPSTREAM_TAG}:Package.swift")"
UPSTREAM_ZIP_URL="$(sed -nE 's#^[[:space:]]*url: "(https://[^"]*/C2PAC\.xcframework\.zip)",?$#\1#p' <<< "${UPSTREAM_MANIFEST}")"
UPSTREAM_CHECKSUM="$(sed -nE 's#^[[:space:]]*checksum: "([0-9a-f]{64})",?$#\1#p' <<< "${UPSTREAM_MANIFEST}")"
[ "$(wc -l <<< "${UPSTREAM_ZIP_URL}" | tr -d ' ')" = "1" ] && [ -n "${UPSTREAM_ZIP_URL}" ] \
  || fail "Expected exactly one C2PAC url in ${UPSTREAM_TAG}'s Package.swift."
[ "$(wc -l <<< "${UPSTREAM_CHECKSUM}" | tr -d ' ')" = "1" ] && [ -n "${UPSTREAM_CHECKSUM}" ] \
  || fail "Expected exactly one checksum in ${UPSTREAM_TAG}'s Package.swift."

echo "==> Downloading ${UPSTREAM_ZIP_URL}"
UPSTREAM_ZIP="${WORK_DIR}/upstream/C2PAC.xcframework.zip"
mkdir -p "$(dirname "${UPSTREAM_ZIP}")"
curl -fsSL -o "${UPSTREAM_ZIP}" "${UPSTREAM_ZIP_URL}"
[ "$(shasum -a 256 "${UPSTREAM_ZIP}" | awk '{print $1}')" = "${UPSTREAM_CHECKSUM}" ] \
  || fail "The downloaded zip doesn't match ${UPSTREAM_TAG}'s checksum ${UPSTREAM_CHECKSUM}."

echo "==> Setting MinimumOSVersion to ${MINIMUM_OS_VERSION}"
EXTRACTED="${WORK_DIR}/extracted"
ditto -x -k "${UPSTREAM_ZIP}" "${EXTRACTED}"
[ -d "${EXTRACTED}/C2PAC.xcframework" ] || fail "The zip doesn't contain C2PAC.xcframework."

# Only the flat (iOS-style) framework layouts have a top-level Info.plist with MinimumOSVersion. The
# versioned macOS layout keeps its plist under Versions/A/Resources, uses LSMinimumSystemVersion and
# ships a dynamic library, so it's left alone.
PATCHED=0
while IFS= read -r PLIST; do
  plutil -extract MinimumOSVersion raw "${PLIST}" > /dev/null 2>&1 || continue
  OLD="$(plutil -extract MinimumOSVersion raw "${PLIST}")"
  plutil -replace MinimumOSVersion -string "${MINIMUM_OS_VERSION}" "${PLIST}"
  echo "  ${PLIST#"${EXTRACTED}/"}: ${OLD} -> ${MINIMUM_OS_VERSION}"
  PATCHED=$((PATCHED + 1))
done < <(find "${EXTRACTED}/C2PAC.xcframework" -path "*/C2PAC.framework/Info.plist")
[ "${PATCHED}" -gt 0 ] || fail "No C2PAC.framework/Info.plist with MinimumOSVersion was found."

ZIP="${WORK_DIR}/C2PAC.xcframework.zip"
(cd "${EXTRACTED}" && zip -qry "${ZIP}" C2PAC.xcframework)
CHECKSUM="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"

echo "==> Committing Package.swift on top of ${UPSTREAM_TAG}"
git worktree add -q --detach "${WORKTREE}" "${UPSTREAM_TAG}"
MANIFEST="${WORKTREE}/Package.swift"
UPSTREAM_ZIP_URL="${UPSTREAM_ZIP_URL}" ASSET_URL="${ASSET_URL}" \
UPSTREAM_CHECKSUM="${UPSTREAM_CHECKSUM}" CHECKSUM="${CHECKSUM}" \
FORK_REPO="${FORK_REPO}" UPSTREAM_TAG="${UPSTREAM_TAG}" MINIMUM_OS_VERSION="${MINIMUM_OS_VERSION}" \
  perl -0pi -e '
    my $comment = "        // Upstream $ENV{UPSTREAM_TAG} C2PAC with MinimumOSVersion $ENV{MINIMUM_OS_VERSION}, published by\n"
                . "        // Scripts/release.sh on the lightricks/release-tools branch of $ENV{FORK_REPO}.\n";
    s/^(\s*\.binaryTarget\(\s*\n\s*name: "C2PAC",)/$comment$1/m or die "No C2PAC binaryTarget found\n";
    s/\Q$ENV{UPSTREAM_ZIP_URL}\E/$ENV{ASSET_URL}/ or die "Upstream url not found\n";
    s/\Q$ENV{UPSTREAM_CHECKSUM}\E/$ENV{CHECKSUM}/ or die "Upstream checksum not found\n";
  ' "${MANIFEST}"
git -C "${WORKTREE}" add Package.swift
git -C "${WORKTREE}" commit -q -F - << EOF
Package: Use C2PAC with MinimumOSVersion ${MINIMUM_OS_VERSION}.

Points the C2PAC binary target at a copy of upstream's ${UPSTREAM_TAG}
C2PAC.xcframework.zip whose C2PAC.framework Info.plists declare
MinimumOSVersion ${MINIMUM_OS_VERSION}, published as an asset of the ${TAG} release.

C2PAC is a static framework, so Xcode embeds a code-less stub dylib for it
built with the app's deployment target as its minos. App Store Connect
rejects a framework whose plist declares a lower minimum OS than its binary
(ITMS-90208), and only checks that the plist value is at least the minos.
EOF
git -C "${WORKTREE}" tag -a "${TAG}" -m "${UPSTREAM_TAG} with C2PAC MinimumOSVersion ${MINIMUM_OS_VERSION}" HEAD
REVISION_SHA="$(git rev-parse "${TAG}^{commit}")"

if [ "${DRY_RUN}" = "true" ]; then
  echo
  echo "Dry run done. Would publish ${TAG} (${REVISION_SHA}) with ${ZIP} (checksum ${CHECKSUM})."
  git -C "${WORKTREE}" --no-pager show --stat --format='%H%n%n%B' HEAD
  git -C "${WORKTREE}" --no-pager diff "${UPSTREAM_TAG}" HEAD
  exit 0
fi

echo "==> Pushing ${TAG} to ${FORK_REPO}"
git push -q "${FORK_URL}" "refs/tags/${TAG}"
TAG_PUSHED="true"

echo "==> Creating the ${TAG} release"
NOTES="Upstream [${UPSTREAM_TAG}](https://github.com/${UPSTREAM_REPO}/releases/tag/${UPSTREAM_TAG}) with MinimumOSVersion ${MINIMUM_OS_VERSION} in every C2PAC.framework/Info.plist, so the stub Xcode embeds for the static framework passes App Store Connect's check (ITMS-90208). The binaries are unchanged.

SHA-256: \`${CHECKSUM}\`"
gh release create "${TAG}" -R "${FORK_REPO}" --verify-tag --title "${TAG}" --notes "${NOTES}" "${ZIP}" > /dev/null

echo "==> Verifying the published asset"
PUBLISHED="${WORK_DIR}/published.zip"
curl -fsSL -o "${PUBLISHED}" "${ASSET_URL}"
[ "$(shasum -a 256 "${PUBLISHED}" | awk '{print $1}')" = "${CHECKSUM}" ] \
  || fail "The published asset at ${ASSET_URL} doesn't match checksum ${CHECKSUM}."

echo
echo "Published ${TAG}: https://github.com/${FORK_REPO}/releases/tag/${TAG}"
echo "  Package URL: https://github.com/${FORK_REPO}"
echo "  Version:     ${VERSION}-lightricks.${REVISION} (exact)"
echo "  Revision:    ${REVISION_SHA}"
echo "  Checksum:    ${CHECKSUM}"
