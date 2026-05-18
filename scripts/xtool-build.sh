#!/usr/bin/env bash
set -euo pipefail

SWIFT_VERSION="6.2.4"
MPVKIT_VERSION="48fa1a1533062ae800772071a0ef6c36f553ba45"
MPVKIT_URL="https://github.com/edde746/MPVKit.git"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

require_command curl
require_command git
require_command perl
require_command sha256sum
require_command swift
require_command swiftly
require_command unzip
require_command xtool

ensure_case_sensitive_dir() {
  local dir="$1"
  mkdir -p "$dir"

  if ! command -v cmd.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
    return
  fi

  local fs_type
  fs_type="$(stat -f -c %T "$dir" 2>/dev/null || echo unknown)"
  if [[ "$fs_type" != "9p" && "$fs_type" != "drvfs" ]]; then
    return
  fi

  local win_dir
  win_dir="$(wslpath -w "$dir")"
  if cmd.exe /c fsutil.exe file queryCaseSensitiveInfo "$win_dir" 2>/dev/null | tr -d '\r' | grep -qi enabled; then
    return
  fi

  if find "$dir" -mindepth 1 -maxdepth 1 | read -r _; then
    if [[ "$dir" == "$ROOT_DIR/.build" ]]; then
      echo "Clearing generated .build so NTFS case sensitivity can be enabled..."
      rm -rf "$dir"
      mkdir -p "$dir"
    else
      echo "Cannot enable case sensitivity for non-empty directory: $dir" >&2
      exit 1
    fi
  fi

  cmd.exe /c fsutil.exe file setCaseSensitiveInfo "$win_dir" enable >/dev/null
}

if ! swiftly list | grep -q "Swift ${SWIFT_VERSION}"; then
  echo "Installing Swift ${SWIFT_VERSION} with swiftly..."
  if ! swiftly install "$SWIFT_VERSION" --assume-yes; then
    if ! swiftly list | grep -q "Swift ${SWIFT_VERSION}"; then
      echo "Swift ${SWIFT_VERSION} did not install successfully." >&2
      echo "On Ubuntu WSL, install Swift dependencies first:" >&2
      echo "sudo apt-get update && sudo apt-get install -y build-essential unzip libncursesw5-dev" >&2
      exit 1
    fi
  fi
fi

printf "%s\n" "$SWIFT_VERSION" > .swift-version
hash -r 2>/dev/null || true

if ! swift --version | grep -q "Swift version ${SWIFT_VERSION}"; then
  echo "Swift ${SWIFT_VERSION} is selected in .swift-version, but swift reports:" >&2
  swift --version >&2
  exit 1
fi

ensure_case_sensitive_dir "$ROOT_DIR/.build"
ensure_case_sensitive_dir "$ROOT_DIR/xtool"

DEPS_ROOT=".build/streamify-deps"
MPVKIT_PACKAGE_DIR="${DEPS_ROOT}/MPVKit"
MPVKIT_MANIFEST="${MPVKIT_PACKAGE_DIR}/Package.swift"

ensure_git_checkout() {
  local package_dir="$1"
  local package_url="$2"
  local package_ref="$3"
  local label="$4"

  if [[ -f "${package_dir}/Package.swift" ]]; then
    return
  fi

  if [[ -e "$package_dir" ]]; then
    rm -rf "$package_dir"
  fi

  mkdir -p "$(dirname "$package_dir")"
  echo "Cloning ${label}..."
  if [[ "$package_ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    git init "$package_dir"
    git -C "$package_dir" remote add origin "$package_url"
    git -C "$package_dir" fetch --depth 1 origin "$package_ref"
    git -C "$package_dir" checkout --detach FETCH_HEAD
  else
    git clone --depth 1 --branch "$package_ref" "$package_url" "$package_dir"
  fi
}

prepare_binary_artifacts_from_manifest() {
  local package_dir="$1"
  local manifest="$2"
  local artifact_dir="${package_dir}/Artifacts"
  local found_remote_targets=0

  mkdir -p "$artifact_dir"

  extract_artifact_zip() {
    local target_name="$1"
    local zip_path="$2"
    local framework_path="${artifact_dir}/${target_name}.xcframework"
    local extract_dir="${artifact_dir}/.extract-${target_name}"

    if [[ -f "${framework_path}/Info.plist" ]]; then
      return
    fi

    echo "Extracting ${target_name}.xcframework..."
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    unzip -q -o "$zip_path" -d "$extract_dir"

    local extracted_framework
    extracted_framework="$(find "$extract_dir" -maxdepth 1 -type d -name '*.xcframework' | head -n 1)"
    if [[ -z "$extracted_framework" ]]; then
      echo "No xcframework found inside ${zip_path}" >&2
      rm -rf "$extract_dir"
      exit 1
    fi

    rm -rf "$framework_path"
    mv "$extracted_framework" "$framework_path"
    rm -rf "$extract_dir"
  }

  while IFS=$'\t' read -r target_name target_url expected_checksum; do
    found_remote_targets=1
    local zip_path="${artifact_dir}/${target_name}.xcframework.zip"
    local actual_checksum=""

    if [[ -f "$zip_path" ]]; then
      actual_checksum="$(sha256sum "$zip_path" | awk '{print $1}')"
    fi

    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
      echo "Downloading ${target_name}.xcframework.zip..."
      curl -fL --retry 3 --output "${zip_path}.tmp" "$target_url"
      actual_checksum="$(sha256sum "${zip_path}.tmp" | awk '{print $1}')"
      if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        echo "Checksum mismatch for ${target_name}.xcframework.zip" >&2
        echo "Expected: $expected_checksum" >&2
        echo "Actual:   $actual_checksum" >&2
        rm -f "${zip_path}.tmp"
        exit 1
      fi
      mv "${zip_path}.tmp" "$zip_path"
    fi

    extract_artifact_zip "$target_name" "$zip_path"
  done < <(perl -0ne 'while (/\.binaryTarget\(\s*name:\s*"([^"]+)",\s*url:\s*"([^"]+)",\s*checksum:\s*"([^"]+)"\s*\)/gs) { print "$1\t$2\t$3\n" }' "$manifest")

  while IFS=$'\t' read -r target_name target_path; do
    local zip_path="${artifact_dir}/${target_name}.xcframework.zip"
    if [[ -f "$zip_path" && "$target_path" == "Artifacts/${target_name}.xcframework" ]]; then
      extract_artifact_zip "$target_name" "$zip_path"
    fi
  done < <(perl -0ne 'while (/\.binaryTarget\(\s*name:\s*"([^"]+)",\s*path:\s*"([^"]+)"\s*\)/gs) { print "$1\t$2\n" }' "$manifest")

  if [[ "$found_remote_targets" == "1" ]]; then
    perl -0pi -e 's@\.binaryTarget\(\s*name:\s*"([^"]+)",\s*url:\s*"[^"]+",\s*checksum:\s*"[^"]+"\s*\)@.binaryTarget(name: "$1", path: "Artifacts/$1.xcframework")@gs' "$manifest"
  fi
}

ensure_git_checkout "$MPVKIT_PACKAGE_DIR" "$MPVKIT_URL" "$MPVKIT_VERSION" "MPVKit ${MPVKIT_VERSION}"
prepare_binary_artifacts_from_manifest "$MPVKIT_PACKAGE_DIR" "$MPVKIT_MANIFEST"

echo "Resolving Swift packages with local binary dependencies..."
swift package resolve

echo "Building app with xtool..."
xtool dev build "$@"

echo "Build complete: ${ROOT_DIR}/xtool/Streamify.app"
echo "For the app to be installable, run remove-unused-frameworks-from-app.sh, or run xtool-install.sh to install the app on your device using xtool."
