#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

install_args=("$@")
if [[ ${#install_args[@]} -eq 0 ]]; then
  install_args=(--usb)
fi

bash "${ROOT_DIR}/scripts/xtool-build.sh"
"${ROOT_DIR}/scripts/remove-unused-frameworks-from-app.sh" "${ROOT_DIR}/xtool/Streamify.app"
xtool install "${install_args[@]}" "${ROOT_DIR}/xtool/Streamify.app"
