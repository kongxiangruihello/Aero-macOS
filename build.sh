#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OUTPUT_DIR="${SCRIPT_DIR}/../../outputs"
APP_DIR="${OUTPUT_DIR}/Kong.app"
STAGING_ROOT="$(mktemp -d /private/tmp/kong-build.XXXXXX)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT
STAGING_APP_DIR="${STAGING_ROOT}/Kong.app"
CONTENTS_DIR="${STAGING_APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MODULE_CACHE_DIR="${SCRIPT_DIR}/.build/ModuleCache"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

if [[ ! -x "${SCRIPT_DIR}/.downloads/mihomo-arm64" || ! -x "${SCRIPT_DIR}/.downloads/mihomo-amd64" ]]; then
  "${SCRIPT_DIR}/download-core.sh"
fi

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${MODULE_CACHE_DIR}"
cp -X "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"

for arch in arm64 x86_64; do
  xcrun swiftc \
    "${SCRIPT_DIR}/Sources/AeroClash/main.swift" \
    "${SCRIPT_DIR}/Sources/AeroClash/Runtime.swift" \
    "${SCRIPT_DIR}/Sources/AeroClash/AdvancedSettings.swift" \
    "${SCRIPT_DIR}/Sources/AeroClash/SubscriptionFormatter.swift" \
    "${SCRIPT_DIR}/Sources/AeroClash/SubscriptionDownloader.swift" \
    -o "${SCRIPT_DIR}/.build/Kong-${arch}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -framework CoreImage \
    -framework Security \
    -parse-as-library \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    -target "${arch}-apple-macos13.0" \
    -O
done

lipo -create \
  "${SCRIPT_DIR}/.build/Kong-arm64" \
  "${SCRIPT_DIR}/.build/Kong-x86_64" \
  -output "${MACOS_DIR}/Kong"

sips -z 1024 1024 "${SCRIPT_DIR}/Assets/ConfuciusIcon.png" --out "${SCRIPT_DIR}/.build/AppIcon.png" >/dev/null
sips -z 20 20 "${SCRIPT_DIR}/Assets/ConfuciusMenuBarIcon.png" --out "${SCRIPT_DIR}/.build/MenuBarIcon.png" >/dev/null
sips -z 40 40 "${SCRIPT_DIR}/Assets/ConfuciusMenuBarIcon.png" --out "${SCRIPT_DIR}/.build/MenuBarIcon@2x.png" >/dev/null

cp -X "${SCRIPT_DIR}/.build/AppIcon.png" "${RESOURCES_DIR}/AppIcon.png"
cp -X "${SCRIPT_DIR}/.build/MenuBarIcon.png" "${RESOURCES_DIR}/MenuBarIcon.png"
cp -X "${SCRIPT_DIR}/.build/MenuBarIcon@2x.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"
lipo -create \
  "${SCRIPT_DIR}/.downloads/mihomo-arm64" \
  "${SCRIPT_DIR}/.downloads/mihomo-amd64" \
  -output "${RESOURCES_DIR}/mihomo"
chmod +x "${RESOURCES_DIR}/mihomo"
cp -X "${SCRIPT_DIR}/Mihomo-NOTICE.txt" "${RESOURCES_DIR}/Mihomo-NOTICE.txt"
cp -X "${SCRIPT_DIR}/Mihomo-LICENSE.txt" "${RESOURCES_DIR}/Mihomo-LICENSE.txt"
xattr -cr "${STAGING_APP_DIR}"
codesign --force --deep --sign - "${STAGING_APP_DIR}" >/dev/null
ditto -c -k --sequesterRsrc --keepParent "${STAGING_APP_DIR}" "${STAGING_ROOT}/Kong-macOS.zip"
ditto --norsrc --noextattr --noacl "${STAGING_APP_DIR}" "${APP_DIR}"
cp -X "${STAGING_ROOT}/Kong-macOS.zip" "${OUTPUT_DIR}/Kong-macOS.zip"
echo "Built ${APP_DIR}"
