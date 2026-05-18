#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-xtool/Streamify.app}"
FRAMEWORKS_PATH="${APP_PATH}/Frameworks"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -d "$FRAMEWORKS_PATH" ]]; then
  echo "No Frameworks directory found in: $APP_PATH"
  exit 0
fi

app_executable_name() {
  local plist="${APP_PATH}/Info.plist"
  local fallback
  fallback="$(basename "$APP_PATH" .app)"

  if [[ -f "$plist" ]]; then
    local executable
    executable="$(perl -0ne 'if (m@<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>@) { print $1; exit }' "$plist" 2>/dev/null || true)"
    if [[ -n "$executable" ]]; then
      printf '%s\n' "$executable"
      return
    fi
  fi

  printf '%s\n' "$fallback"
}

executable_path="${APP_PATH}/$(app_executable_name)"

otool_command=""
if command -v otool >/dev/null 2>&1; then
  otool_command="otool"
elif command -v llvm-otool >/dev/null 2>&1; then
  otool_command="llvm-otool"
fi

framework_executable() {
  local framework_path="$1"
  local framework_name
  framework_name="$(basename "$framework_path" .framework)"
  local default_path="${framework_path}/${framework_name}"

  if [[ -f "$default_path" ]]; then
    printf '%s\n' "$default_path"
    return
  fi

  local plist="${framework_path}/Info.plist"
  if [[ -f "$plist" ]]; then
    local executable
    executable="$(perl -0ne 'if (m@<key>CFBundleExecutable</key>\s*<string>([^<]+)</string>@) { print $1; exit }' "$plist" 2>/dev/null || true)"
    if [[ -n "$executable" && -f "${framework_path}/${executable}" ]]; then
      printf '%s\n' "${framework_path}/${executable}"
      return
    fi
  fi

  printf '%s\n' "$default_path"
}

linked_embedded_artifact_names() {
  local queue=()
  local index=0
  local linked_file
  local processed_file
  linked_file="$(mktemp)"
  processed_file="$(mktemp)"

  if [[ -f "$executable_path" ]]; then
    queue+=("$executable_path")
  fi

  linked_artifacts_for_file() {
    local file="$1"
    if [[ -n "$otool_command" ]]; then
      "$otool_command" -L "$file" 2>/dev/null | awk '
        /@rpath\// {
          path=$1
          sub(/^@rpath\//, "", path)
          if (path ~ /^[^[:space:]]+\.dylib$/) {
            print path
          } else if (path ~ /^[^[:space:]]+\.framework\//) {
            sub(/\/.*/, "", path)
            print path
          }
        }'
    elif command -v strings >/dev/null 2>&1; then
      strings "$file" 2>/dev/null | awk '
        /^@rpath\// {
          path=$1
          sub(/^@rpath\//, "", path)
          if (path ~ /^[^[:space:]]+\.dylib$/) {
            print path
          } else if (path ~ /^[^[:space:]]+\.framework\//) {
            sub(/\/.*/, "", path)
            print path
          }
        }'
    fi
  }

  while [[ "$index" -lt "${#queue[@]}" ]]; do
    local file="${queue[$index]}"
    index=$((index + 1))
    [[ -f "$file" ]] || continue
    if grep -Fxq "$file" "$processed_file"; then
      continue
    fi
    printf '%s\n' "$file" >> "$processed_file"

    while IFS= read -r artifact_name; do
      [[ -n "$artifact_name" ]] || continue
      if ! grep -Fxq "$artifact_name" "$linked_file"; then
        printf '%s\n' "$artifact_name" >> "$linked_file"
      fi

      local dependency_path=""
      if [[ "$artifact_name" == *.dylib && -f "${FRAMEWORKS_PATH}/${artifact_name}" ]]; then
        dependency_path="${FRAMEWORKS_PATH}/${artifact_name}"
      elif [[ "$artifact_name" == *.framework && -d "${FRAMEWORKS_PATH}/${artifact_name}" ]]; then
        dependency_path="$(framework_executable "${FRAMEWORKS_PATH}/${artifact_name}")"
      fi

      if [[ -n "$dependency_path" && -f "$dependency_path" ]] &&
          ! grep -Fxq "$dependency_path" "$processed_file"; then
        queue+=("$dependency_path")
      fi
    done < <(linked_artifacts_for_file "$file")
  done

  sort -u "$linked_file"
  rm -f "$linked_file" "$processed_file"
}

linked_artifacts="$(linked_embedded_artifact_names)"

is_linked_artifact() {
  local artifact_name="$1"
  [[ -n "$linked_artifacts" ]] && printf '%s\n' "$linked_artifacts" | grep -Fxq "$artifact_name"
}

is_static_framework() {
  local framework_path="$1"
  local binary
  binary="$(framework_executable "$framework_path")"
  [[ -f "$binary" ]] || return 1
  file "$binary" 2>/dev/null | grep -q 'current ar archive'
}

removed_framework_count=0
while IFS= read -r framework; do
  framework_name="$(basename "$framework")"
  if is_static_framework "$framework"; then
    echo "Removing unused embedded framework bundle: ${framework_name}"
    rm -rf "$framework"
    removed_framework_count=$((removed_framework_count + 1))
  elif ! is_linked_artifact "$framework_name"; then
    echo "Removing unlinked dynamic framework bundle: ${framework_name}"
    rm -rf "$framework"
    removed_framework_count=$((removed_framework_count + 1))
  fi
done < <(find "$FRAMEWORKS_PATH" -maxdepth 1 -type d -name '*.framework' 2>/dev/null)

removed_dylib_count=0
while IFS= read -r dylib; do
  dylib_name="$(basename "$dylib")"
  if ! is_linked_artifact "$dylib_name"; then
    echo "Removing unlinked dynamic library: ${dylib_name}"
    rm -f "$dylib"
    removed_dylib_count=$((removed_dylib_count + 1))
  fi
done < <(find "$FRAMEWORKS_PATH" -maxdepth 1 -type f -name '*.dylib' 2>/dev/null)

remaining_count="$(find "$FRAMEWORKS_PATH" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')"
if [[ "$remaining_count" == "0" ]]; then
  echo "Removing empty Frameworks directory from app bundle."
  rm -rf "$FRAMEWORKS_PATH"
else
  echo "Kept Frameworks directory with ${remaining_count} linked embedded artifact(s); removed ${removed_framework_count} framework bundle(s) and ${removed_dylib_count} dylib(s)."
fi
