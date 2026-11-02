#!/bin/zsh
# Build the offline IDEA plugin using the installed SDK and macOS tools.
set -euo pipefail

PLUGIN_SCRIPT_DIR="${0:A:h}"
PLUGIN_PROJECT_DIR="${PLUGIN_SCRIPT_DIR:h}"
PLUGIN_IDE_APP="/Applications/IntelliJ IDEA.app"
PLUGIN_OUTPUT="${PLUGIN_PROJECT_DIR}/Resources/IDEPlugins/cc-pets-terminal.zip"

usage() {
  print -r -- "Usage: ${0:t} [--ide <IDEA.app>] [--output <plugin.zip>]

Build against an installed IDEA 2026.2 / 2026.3 SDK without downloading dependencies.
Uses the IDE's bundled Java 25 compiler, or JAVA_HOME when explicitly set.
Defaults:
  --ide     /Applications/IntelliJ IDEA.app
  --output  Resources/IDEPlugins/cc-pets-terminal.zip (in this repository)"
}

while (( $# > 0 )); do
  case "$1" in
    --ide|--output)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        print -u2 -r -- "Missing value for $1"
        exit 2
      fi
      if [[ "$1" == --ide ]]; then PLUGIN_IDE_APP="$2"; else PLUGIN_OUTPUT="$2"; fi
      shift 2
      ;;
    --ide=*) PLUGIN_IDE_APP="${1#--ide=}"; shift ;;
    --output=*) PLUGIN_OUTPUT="${1#--output=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -r -- "Unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PLUGIN_IDE_APP" || -z "$PLUGIN_OUTPUT" ]]; then
  print -u2 -- "IDEA app and output paths must not be empty."
  exit 2
fi
PLUGIN_SDK_DIR="${PLUGIN_IDE_APP:A}/Contents"
PLUGIN_OUTPUT="${PLUGIN_OUTPUT:a}"
PLUGIN_SOURCE_DIR="${PLUGIN_PROJECT_DIR}/plugins/jetbrains/src/main"
PLUGIN_JAVA_HOME="${JAVA_HOME:-${PLUGIN_SDK_DIR}/jbr/Contents/Home}"
PLUGIN_JAVA="${PLUGIN_JAVA_HOME}/bin/java"
PLUGIN_JARS=("${PLUGIN_SDK_DIR}"/lib/*.jar(N) "${PLUGIN_SDK_DIR}"/plugins/terminal/lib/**/*.jar(N))
PLUGIN_SOURCES=("${PLUGIN_SOURCE_DIR}"/java/**/*.java(N))
if (( ${#PLUGIN_JARS[@]} == 0 )) || [[ ! -f "${PLUGIN_SDK_DIR}/plugins/terminal/lib/terminal.jar" ]]; then
  print -u2 -r -- "IDEA SDK with the bundled Terminal plugin was not found: ${PLUGIN_SDK_DIR}"
  exit 1
fi
if [[ ! -x "$PLUGIN_JAVA" ]] || (( ${#PLUGIN_SOURCES[@]} == 0 )); then
  print -u2 -- "The Java runtime or plugin Java sources are missing."
  exit 1
fi
/usr/bin/xmllint --nonet --noout "${PLUGIN_SOURCE_DIR}/resources/META-INF/plugin.xml"

PLUGIN_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-pets-idea-build.XXXXXX")"
PLUGIN_STAGED_OUTPUT=""
cleanup() {
  [[ -z "$PLUGIN_STAGED_OUTPUT" ]] || rm -f -- "$PLUGIN_STAGED_OUTPUT"
  rm -rf -- "$PLUGIN_BUILD_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "${PLUGIN_BUILD_DIR}/classes/META-INF" "${PLUGIN_BUILD_DIR}/distribution/cc-pets-terminal/lib"

# The bundled runtime contains jdk.compiler even when it has no javac launcher.
"$PLUGIN_JAVA" -m jdk.compiler/com.sun.tools.javac.Main \
  --release 25 -proc:none -Xlint:deprecation \
  -d "${PLUGIN_BUILD_DIR}/classes" \
  -classpath "${(j.:.)PLUGIN_JARS}" \
  "${PLUGIN_SOURCES[@]}"
cp -R "${PLUGIN_SOURCE_DIR}/resources/." "${PLUGIN_BUILD_DIR}/classes/"

# Only archive files, in sorted order, with fixed timestamps and permissions.
# This keeps repeated builds reproducible without Python or a jar launcher.
(
  cd "${PLUGIN_BUILD_DIR}/classes"
  PLUGIN_CLASS_FILES=(**/*(.N))
  chmod 644 "${PLUGIN_CLASS_FILES[@]}"
  TZ=UTC /usr/bin/touch -t 202601010000.00 "${PLUGIN_CLASS_FILES[@]}"
  TZ=UTC /usr/bin/zip -X -q -9 "${PLUGIN_BUILD_DIR}/distribution/cc-pets-terminal/lib/cc-pets-terminal.jar" \
    "${PLUGIN_CLASS_FILES[@]}"
)
(
  cd "${PLUGIN_BUILD_DIR}/distribution"
  chmod 644 cc-pets-terminal/lib/cc-pets-terminal.jar
  TZ=UTC /usr/bin/touch -t 202601010000.00 cc-pets-terminal/lib/cc-pets-terminal.jar
  TZ=UTC /usr/bin/zip -X -q -9 "${PLUGIN_BUILD_DIR}/cc-pets-terminal.zip" cc-pets-terminal/lib/cc-pets-terminal.jar
)

# Publish only after compilation and both archives have completed successfully.
mkdir -p "${PLUGIN_OUTPUT:h}"
PLUGIN_STAGED_OUTPUT="$(mktemp "${PLUGIN_OUTPUT:h}/.cc-pets-plugin.XXXXXX")"
cp "${PLUGIN_BUILD_DIR}/cc-pets-terminal.zip" "$PLUGIN_STAGED_OUTPUT"
chmod 644 "$PLUGIN_STAGED_OUTPUT"
mv -f -- "$PLUGIN_STAGED_OUTPUT" "$PLUGIN_OUTPUT"
PLUGIN_STAGED_OUTPUT=""
print -r -- "Built IDEA plugin: ${PLUGIN_OUTPUT}"
