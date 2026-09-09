#!/bin/bash
#
# Publish one SHA256SUMS for a release (chdb-io/chdb-core#217).
#
# A release asset carries no checksum a consumer can fetch, so everything downstream can
# only verify that the URL answered. chdb-rust pins an engine version and fetches
# <platform>-libchdb[-static].tar.gz from that release during `cargo build`; the pin names
# one release but does not make the build reproducible, because nothing checks the bytes are
# the ones the release was cut with. A replaced or truncated asset produces a build that
# looks fine. chdb-go, packagers and anyone scripting an install are in the same position.
#
# The file this writes is `sha256sum -c` / `shasum -a 256 -c` format - `<hex>  <name>`, one
# line per asset, sorted by name - so a consumer verifies with the tool it already has, from
# a plain download URL, with no API call and no token.
#
# The digests come from GitHub's own per-asset `digest` field, which it computes over the
# stored bytes at upload time. Restating them as a file is the point: the field is only
# reachable one asset at a time through the API, which is not something a `cargo build`
# script or an install one-liner is going to do. Assets predating that field - or carrying a
# digest in some algorithm other than sha256 - are downloaded and hashed here instead, one
# at a time and deleted straight after, because the four platforms together are around nine
# gigabytes and a hosted runner has about fourteen free.
#
# A fallback download is checked against the size the API reports before it is hashed. A
# truncated download would otherwise be published as an authoritative checksum for a
# complete file, which is worse than publishing nothing.
#
# Assets that are still uploading are fatal, not skipped. Skipping would quietly produce a
# SHA256SUMS that is missing a line, and a consumer cannot tell that from an asset that was
# never meant to be covered.
#
# Safe to run repeatedly: each run rewrites the file from whatever the release holds at that
# moment, and the run after the last upload is the one that is complete.
#
# Usage: publish-release-checksums.sh <tag> [--dry-run]
#   GH_TOKEN  needs contents:write unless --dry-run
#   GH_REPO   defaults to the repository gh infers from the checkout

set -euo pipefail

TAG=${1:-}
DRY_RUN=${2:-}

if [ -z "${TAG}" ]; then
    echo "Usage: $0 <tag> [--dry-run]" >&2
    exit 2
fi
if [ -n "${DRY_RUN}" ] && [ "${DRY_RUN}" != "--dry-run" ]; then
    echo "Error: unknown argument '${DRY_RUN}' (expected --dry-run)" >&2
    exit 2
fi

CHECKSUM_FILE=SHA256SUMS

# Coreutils on Linux, the BSD spelling on macOS. Resolved once so the failure is "no sha256
# tool" rather than a confusing error from inside the loop.
if command -v sha256sum > /dev/null 2>&1; then
    sha256_of () { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum > /dev/null 2>&1; then
    sha256_of () { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    echo "Error: neither sha256sum nor shasum is available" >&2
    exit 1
fi

# stat's spelling differs the same way.
if stat -c %s . > /dev/null 2>&1; then
    size_of () { stat -c %s "$1"; }
else
    size_of () { stat -f %z "$1"; }
fi

is_sha256 () { printf '%s' "$1" | grep -Eq '^[0-9a-f]{64}$'; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Release checksums for ${TAG}"

# Tab separated so a name with spaces still parses. SHA256SUMS itself is excluded because it
# is the output, and including it would make the file describe its own previous revision.
# apiUrl carries the numeric asset id the REST download endpoint wants; the `id` field is
# the GraphQL node id, which that endpoint does not accept.
if ! gh release view "${TAG}" --json assets \
        --jq '.assets[]
              | select(.name != "'"${CHECKSUM_FILE}"'")
              | [.name, .size, .state, (.apiUrl | split("/") | last), (.digest // "")]
              | @tsv' \
        > "${WORK_DIR}/assets.tsv"; then
    echo "Error: no release ${TAG}, or its assets could not be listed" >&2
    exit 1
fi
sort "${WORK_DIR}/assets.tsv" -o "${WORK_DIR}/assets.tsv"

asset_count=$(wc -l < "${WORK_DIR}/assets.tsv" | tr -d ' ')
if [ "${asset_count}" -eq 0 ]; then
    echo "Error: ${TAG} has no assets besides ${CHECKSUM_FILE}; refusing to publish an empty file" >&2
    exit 1
fi
echo "  ${asset_count} asset(s)"
echo

: > "${WORK_DIR}/${CHECKSUM_FILE}"
while IFS=$'\t' read -r name size state asset_id reported; do
    if [ "${state}" != "uploaded" ]; then
        echo "Error: ${name} is in state '${state}', not 'uploaded'; its bytes are not final yet" >&2
        exit 1
    fi

    digest=""
    note=""

    # GitHub's own digest, when it has one and it is sha256.
    case "${reported}" in
        sha256:*)
            candidate=${reported#sha256:}
            if is_sha256 "${candidate}"; then
                digest=${candidate}
                note="from the release"
            else
                echo "  ${name}: the release reports a malformed sha256, hashing it instead"
            fi
            ;;
        "") ;;
        *) echo "  ${name}: the release reports ${reported%%:*}, not sha256, hashing it instead" ;;
    esac

    if [ -z "${digest}" ]; then
        # By asset id rather than `gh release download --pattern`: the pattern is a glob, and
        # an asset name is not one. `gh api` follows the redirect to the storage backend and
        # streams the body, so nothing is held in memory.
        target="${WORK_DIR}/asset.bin"
        rm -f "${target}"
        if ! gh api -H "Accept: application/octet-stream" \
                "repos/{owner}/{repo}/releases/assets/${asset_id}" \
                > "${target}" < /dev/null; then
            echo "Error: could not download ${name}" >&2
            exit 1
        fi

        downloaded=$(size_of "${target}")
        if [ "${downloaded}" != "${size}" ]; then
            echo "Error: ${name} downloaded as ${downloaded} bytes, the release says ${size}" >&2
            exit 1
        fi

        digest=$(sha256_of "${target}")
        rm -f "${target}"
        note="hashed here"
    fi

    printf '%s  %s\n' "${digest}" "${name}" >> "${WORK_DIR}/${CHECKSUM_FILE}"
    printf '  %s  %s (%s)\n' "${digest}" "${name}" "${note}"
done < "${WORK_DIR}/assets.tsv"

lines=$(wc -l < "${WORK_DIR}/${CHECKSUM_FILE}" | tr -d ' ')
if [ "${lines}" -ne "${asset_count}" ]; then
    echo "Error: wrote ${lines} lines for ${asset_count} assets" >&2
    exit 1
fi

echo
if [ "${DRY_RUN}" = "--dry-run" ]; then
    echo "--dry-run: not uploading. ${CHECKSUM_FILE} would be:"
    sed 's/^/  /' "${WORK_DIR}/${CHECKSUM_FILE}"
    exit 0
fi

gh release upload "${TAG}" "${WORK_DIR}/${CHECKSUM_FILE}" --clobber
echo "Uploaded ${CHECKSUM_FILE} (${lines} entries) to ${TAG}"
