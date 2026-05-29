#!/usr/bin/env bash
set -euo pipefail

# Builds a WoW-installable addon archive from the TOC runtime file list.
# The package intentionally excludes tests, documentation, repository metadata,
# and development-only files by copying only the TOC and files referenced by it.

addon_name="${ADDON_NAME:-BossTracker}"
toc_file="${TOC_FILE:-${addon_name}.toc}"
dist_dir="${DIST_DIR:-dist}"

fail() {
  echo "error: $*" >&2
  exit 1
}

trim_line() {
  sed -E 's/\r$//; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

extract_version() {
  local version
  version="$(awk -F': *' '/^##[[:space:]]*Version[[:space:]]*:/ { print $2; exit }' "${toc_file}" | tr -d '\r')"
  if [ -z "${version}" ]; then
    fail "No '## Version:' entry found in ${toc_file}."
  fi
  echo "${version}"
}

normalize_toc_path() {
  local toc_path="$1"
  local source_path
  source_path="${toc_path//\\//}"

  case "${source_path}" in
    /* | ../* | */../* | */..)
      fail "Unsafe path listed in ${toc_file}: ${toc_path}"
      ;;
  esac

  echo "${source_path}"
}

[ -f "${toc_file}" ] || fail "TOC file not found: ${toc_file}"
command -v zip >/dev/null 2>&1 || fail "zip command is required to build the release archive."

version="${RELEASE_VERSION:-$(extract_version)}"
archive_name="${addon_name}-v${version}.zip"
archive_path="${dist_dir}/${archive_name}"
stage_root="${dist_dir}/.package-${addon_name}"
package_root="${stage_root}/${addon_name}"

rm -rf "${stage_root}" "${archive_path}"
mkdir -p "${package_root}"
cp "${toc_file}" "${package_root}/"

while IFS= read -r raw_line; do
  toc_path="$(printf '%s' "${raw_line}" | trim_line)"

  if [ -z "${toc_path}" ]; then
    continue
  fi

  case "${toc_path}" in
    \#*)
      continue
      ;;
  esac

  source_path="$(normalize_toc_path "${toc_path}")"
  [ -f "${source_path}" ] || fail "File listed in ${toc_file} not found: ${toc_path}"

  target_path="${package_root}/${source_path}"
  mkdir -p "$(dirname "${target_path}")"
  cp "${source_path}" "${target_path}"
done < "${toc_file}"

(
  cd "${stage_root}"
  zip -qr "../${archive_name}" "${addon_name}"
)

rm -rf "${stage_root}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=${version}"
    echo "archive_name=${archive_name}"
    echo "archive_path=${archive_path}"
  } >> "${GITHUB_OUTPUT}"
fi

echo "Built ${archive_path}"
