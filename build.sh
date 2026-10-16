#!/bin/bash
#
# Build and sign LoginScriptPlugin.bundle with clang, without the Xcode
# project. The result is written to build/LoginScriptPlugin.bundle.
#
# Usage:
#   ./build.sh "Apple Development: Your Name (TEAMID)"
#
# Run it without arguments to list the signing identities in your keychain.
#
# Optional environment variables:
#   ARCHS      architectures to build (default: this Mac's, e.g. arm64)
#   MIN_MACOS  oldest macOS version the plugin should load on (default: 11.0)
#   BUNDLE_ID  bundle identifier (default: local.LoginScriptPlugin)


set -o errexit
set -o nounset
set -o pipefail

declare -r PLUGIN="LoginScriptPlugin"
declare -r BUNDLE="build/$PLUGIN.bundle"

ARCHS="${ARCHS:-$(uname -m)}"
MIN_MACOS="${MIN_MACOS:-11.0}"
BUNDLE_ID="${BUNDLE_ID:-local.$PLUGIN}"


function usage() {
    echo "Usage: $(basename "$0") \"<signing identity>\""
    echo
    echo "Signing identities in your keychain:"
    security find-identity -v -p codesigning | sed 's/^/    /'
}

function main() {
    local identity="${1:-}"
    local arch_flags=()
    local arch

    if [[ -z "$identity" ]]; then
        usage
        return 64 # EX_USAGE
    fi

    # Build from the repository root with relative paths, so the binary
    # doesn't contain the path of your checkout.
    cd "$(dirname "$0")"

    for arch in $ARCHS; do
        arch_flags+=(-arch "$arch")
    done

    echo "* Building $BUNDLE ($ARCHS, macOS $MIN_MACOS or later)"
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS"

    # Fill in the Xcode placeholders in Info.plist.
    sed -e 's/\$(EXECUTABLE_NAME)/'"$PLUGIN"'/' \
        -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/'"$BUNDLE_ID"'/' \
        -e 's/\$(PRODUCT_NAME)/'"$PLUGIN"'/' \
        "$PLUGIN/Info.plist" > "$BUNDLE/Contents/Info.plist"

    # asl_log() is deprecated but still compiles, and the #warning is about
    # the *-user script modes, which run in root's session.
    clang "${arch_flags[@]}" -bundle -O2 -mmacosx-version-min="$MIN_MACOS" \
        -Wno-deprecated-declarations -Wno-#warnings \
        -framework Security -framework CoreFoundation \
        -o "$BUNDLE/Contents/MacOS/$PLUGIN" "$PLUGIN/$PLUGIN.c"

    echo "* Signing with \"$identity\""
    if [[ "$identity" == "-" ]]; then
        echo "Warning: ad-hoc signatures haven't been tested, macOS may refuse to load the plugin"
        codesign --force --options runtime --sign - "$BUNDLE"
    elif ! codesign --force --options runtime --timestamp --sign "$identity" "$BUNDLE"; then
        echo
        echo "Signing failed. If the error was errSecInternalComponent and you're"
        echo "connected over SSH, unlock your keychain and run this script again:"
        echo "    security unlock-keychain ~/Library/Keychains/login.keychain-db"
        return 1
    fi
    codesign --verify --strict --verbose=2 "$BUNDLE"

    echo "* Built $(pwd)/$BUNDLE"
    return 0
}

main "$@"
