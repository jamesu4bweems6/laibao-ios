#!/usr/bin/env bash
set -euo pipefail

# Build an unsigned iOS .ipa for LaiBao (来宝接龙) without Apple Developer signing.
# Usage:
#   bash scripts/build-unsigned-ipa.sh [--regenerate-project] [--configuration Release|Debug] [--output dist/LaiBao-unsigned.ipa] [--clean]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${PROJECT_DIR}/LaiBao.xcodeproj"
SCHEME="LaiBao"
APP_NAME="LaiBao"
CONFIGURATION="Release"
OUTPUT_IPA="${PROJECT_DIR}/dist/LaiBao-unsigned.ipa"
REGENERATE_PROJECT=0
CLEAN_BUILD=0

usage() {
  cat <<'EOF'
Usage: bash scripts/build-unsigned-ipa.sh [options]

Options:
  --regenerate-project      Run `xcodegen generate` before building (requires xcodegen).
  --configuration <cfg>     Build configuration: Release (default) or Debug.
  --output <path>           Output .ipa path (default: dist/LaiBao-unsigned.ipa).
  --clean                   Run `xcodebuild clean` before building.
  -h, --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --regenerate-project)
      REGENERATE_PROJECT=1
      shift
      ;;
    --configuration)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --configuration requires an argument" >&2
        exit 1
      fi
      CONFIGURATION="$2"
      shift 2
      ;;
    --output)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --output requires an argument" >&2
        exit 1
      fi
      case "$2" in
        /*) OUTPUT_IPA="$2" ;;
        *)  OUTPUT_IPA="${PROJECT_DIR}/$2" ;;
      esac
      shift 2
      ;;
    --clean)
      CLEAN_BUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found. Please run this script on macOS with Xcode installed." >&2
  exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
  echo "ERROR: zip not found." >&2
  exit 1
fi

if [[ "${REGENERATE_PROJECT}" -eq 1 ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: --regenerate-project requested, but xcodegen is not installed (brew install xcodegen)." >&2
    exit 1
  fi
  echo "==> Regenerating LaiBao.xcodeproj via xcodegen..."
  (cd "${PROJECT_DIR}" && xcodegen generate --spec "${PROJECT_DIR}/project.yml")
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "ERROR: Xcode project not found at ${PROJECT_PATH}" >&2
  exit 1
fi

DERIVED_DATA_DIR="${PROJECT_DIR}/build/DerivedData"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/laibao-ipa-stage.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT

mkdir -p "$(dirname "${OUTPUT_IPA}")" "${DERIVED_DATA_DIR}"

echo "==> Toolchain:"
xcodebuild -version

UNSIGNED_FLAGS=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  CODE_SIGN_STYLE=Manual
  AD_HOC_CODE_SIGNING_ALLOWED=NO
  EXPANDED_CODE_SIGN_IDENTITY=""
  DEVELOPMENT_TEAM=""
  PROVISIONING_PROFILE_SPECIFIER=""
)

if [[ "${CLEAN_BUILD}" -eq 1 ]]; then
  echo "==> Cleaning ${SCHEME} (${CONFIGURATION})..."
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -sdk iphoneos \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    "${UNSIGNED_FLAGS[@]}" \
    clean
fi

echo "==> Building ${SCHEME}.app (${CONFIGURATION}, iphoneos, unsigned)..."
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED_DATA_DIR}" \
  "${UNSIGNED_FLAGS[@]}" \
  build

APP_PATH="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

echo "==> Staging Payload/${APP_NAME}.app..."
PAYLOAD_DIR="${STAGE_DIR}/Payload"
PAYLOAD_APP="${PAYLOAD_DIR}/${APP_NAME}.app"
mkdir -p "${PAYLOAD_DIR}"
if command -v ditto >/dev/null 2>&1; then
  ditto "${APP_PATH}" "${PAYLOAD_APP}"
else
  cp -R "${APP_PATH}" "${PAYLOAD_APP}"
fi

echo "==> Stripping any accidental signing artifacts..."
find "${PAYLOAD_APP}" \( \
  -name "_CodeSignature" -o \
  -name "embedded.mobileprovision" -o \
  -name "SC_Info" -o \
  -name "CodeResources" \
\) -prune -exec rm -rf {} +

if [[ ! -f "${PAYLOAD_APP}/Info.plist" || ! -f "${PAYLOAD_APP}/${APP_NAME}" ]]; then
  echo "ERROR: Staged app bundle is missing Info.plist or main executable (${APP_NAME})." >&2
  exit 1
fi

LEFTOVER_SIGN="$(find "${PAYLOAD_APP}" \( -name "_CodeSignature" -o -name "embedded.mobileprovision" -o -name "SC_Info" \) -print)"
if [[ -n "${LEFTOVER_SIGN}" ]]; then
  echo "ERROR: Signing artifacts still present: ${LEFTOVER_SIGN}" >&2
  exit 1
fi

echo "==> Packaging ${OUTPUT_IPA}..."
rm -f "${OUTPUT_IPA}"
(
  cd "${STAGE_DIR}"
  zip -qry "${OUTPUT_IPA}" Payload
)

if [[ ! -f "${OUTPUT_IPA}" ]]; then
  echo "ERROR: Failed to create ${OUTPUT_IPA}" >&2
  exit 1
fi

echo "==> Archive summary:"
ls -lh "${OUTPUT_IPA}"
if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${OUTPUT_IPA}"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${OUTPUT_IPA}"
fi

echo "==> Archive contents verification (unzip -l):"
unzip -l "${OUTPUT_IPA}"

echo "==> Done: ${OUTPUT_IPA}"
