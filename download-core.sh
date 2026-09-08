#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
DOWNLOAD_DIR="${SCRIPT_DIR}/.downloads"
mkdir -p "${DOWNLOAD_DIR}"

ARM_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/assets/516687188"
AMD_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/assets/516687197"
ARM_SHA="2c7f3a7904fa1cee291e124123e630e7b1ebd13765dd9bf26c0a28432004d9f4"
AMD_SHA="6e75de0732e8afabe413ff7c235e8f16226ce136672371c60787cbf9607402c5"

download_and_verify() {
  local url="$1"
  local archive="$2"
  local executable="$3"
  local expected="$4"
  curl -L --fail --retry 3 -H 'Accept: application/octet-stream' -o "${archive}" "${url}"
  local actual
  actual="$(shasum -a 256 "${archive}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "SHA-256 verification failed for ${archive}" >&2
    exit 1
  fi
  gzip -dc "${archive}" > "${executable}"
  chmod +x "${executable}"
}

download_and_verify "${ARM_URL}" "${DOWNLOAD_DIR}/mihomo-arm64.gz" "${DOWNLOAD_DIR}/mihomo-arm64" "${ARM_SHA}"
download_and_verify "${AMD_URL}" "${DOWNLOAD_DIR}/mihomo-amd64.gz" "${DOWNLOAD_DIR}/mihomo-amd64" "${AMD_SHA}"

echo "Mihomo v1.19.30 downloaded and verified."
