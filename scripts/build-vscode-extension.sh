#!/bin/zsh
# Package the VS Code extension as a VSIX with macOS tools only (no Node, npm or vsce).
# A VSIX is a ZIP holding [Content_Types].xml, extension.vsixmanifest and extension/.
set -euo pipefail

EXT_SCRIPT_DIR="${0:A:h}"
EXT_PROJECT_DIR="${EXT_SCRIPT_DIR:h}"
EXT_SOURCE_DIR="${EXT_PROJECT_DIR}/plugins/vscode"
EXT_OUTPUT="${EXT_PROJECT_DIR}/Resources/IDEPlugins/cc-pets-terminal.vsix"

usage() {
  print -r -- "Usage: ${0:t} [--output <extension.vsix>]

Defaults:
  --output  Resources/IDEPlugins/cc-pets-terminal.vsix (in this repository)"
}

while (( $# > 0 )); do
  case "$1" in
    --output)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        print -u2 -r -- "Missing value for $1"
        exit 2
      fi
      EXT_OUTPUT="$2"; shift 2 ;;
    --output=*) EXT_OUTPUT="${1#--output=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -r -- "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done
EXT_OUTPUT="${EXT_OUTPUT:a}"

EXT_FILES=(package.json extension.js)
for file in "${EXT_FILES[@]}"; do
  [[ -f "${EXT_SOURCE_DIR}/${file}" ]] || { print -u2 -r -- "Missing ${EXT_SOURCE_DIR}/${file}"; exit 1; }
done
manifest_value() { /usr/bin/plutil -extract "$1" raw -o - "${EXT_SOURCE_DIR}/package.json"; }
EXT_VERSION="$(manifest_value version)"
EXT_PUBLISHER="$(manifest_value publisher)"
EXT_NAME="$(manifest_value name)"
EXT_DISPLAY="$(manifest_value displayName)"
EXT_DESCRIPTION="$(manifest_value description)"
EXT_ENGINE="$(manifest_value engines.vscode)"
if [[ ! "$EXT_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -r -- "Invalid extension version: ${EXT_VERSION}"
  exit 1
fi

EXT_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-pets-vscode-build.XXXXXX")"
EXT_STAGED_OUTPUT=""
cleanup() {
  [[ -z "$EXT_STAGED_OUTPUT" ]] || rm -f -- "$EXT_STAGED_OUTPUT"
  rm -rf -- "$EXT_BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${EXT_BUILD_DIR}/extension"
for file in "${EXT_FILES[@]}"; do cp "${EXT_SOURCE_DIR}/${file}" "${EXT_BUILD_DIR}/extension/"; done
[[ ! -f "${EXT_PROJECT_DIR}/LICENSE" ]] || cp "${EXT_PROJECT_DIR}/LICENSE" "${EXT_BUILD_DIR}/extension/LICENSE.txt"

cat > "${EXT_BUILD_DIR}/extension.vsixmanifest" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="${EXT_NAME}" Version="${EXT_VERSION}" Publisher="${EXT_PUBLISHER}" />
    <DisplayName>${EXT_DISPLAY}</DisplayName>
    <Description xml:space="preserve">${EXT_DESCRIPTION}</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="${EXT_ENGINE}" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" />
  </Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
  </Assets>
</PackageManifest>
EOF

cat > "${EXT_BUILD_DIR}/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json" />
  <Default Extension=".js" ContentType="application/javascript" />
  <Default Extension=".txt" ContentType="text/plain" />
  <Default Extension=".vsixmanifest" ContentType="text/xml" />
</Types>
EOF
/usr/bin/xmllint --nonet --noout "${EXT_BUILD_DIR}/extension.vsixmanifest" "${EXT_BUILD_DIR}/[Content_Types].xml"

# Sorted entries, fixed timestamps and permissions keep repeated builds reproducible.
(
  cd "$EXT_BUILD_DIR"
  EXT_ENTRIES=("[Content_Types].xml" extension.vsixmanifest extension/**/*(.N))
  chmod 644 "${EXT_ENTRIES[@]}"
  TZ=UTC /usr/bin/touch -t 202601010000.00 "${EXT_ENTRIES[@]}"
  TZ=UTC /usr/bin/zip -X -q -9 -D "${EXT_BUILD_DIR}/cc-pets-terminal.vsix" "${EXT_ENTRIES[@]}"
)

mkdir -p "${EXT_OUTPUT:h}"
EXT_STAGED_OUTPUT="$(mktemp "${EXT_OUTPUT:h}/.cc-pets-vsix.XXXXXX")"
cp "${EXT_BUILD_DIR}/cc-pets-terminal.vsix" "$EXT_STAGED_OUTPUT"
chmod 644 "$EXT_STAGED_OUTPUT"
mv -f -- "$EXT_STAGED_OUTPUT" "$EXT_OUTPUT"
EXT_STAGED_OUTPUT=""
print -r -- "Built VS Code extension ${EXT_VERSION}: ${EXT_OUTPUT}"
