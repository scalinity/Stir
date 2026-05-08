#!/bin/bash
#
# check-version-sync.sh — assert CFBundleShortVersionString and
# CFBundleVersion match across pbxproj MARKETING_VERSION /
# CURRENT_PROJECT_VERSION and the 3 Info.plist literals.
#
# Rationale (SCA-92): Info.plist values must remain string literals
# (linter policy reverts $(VAR) substitution). With literals in plists
# and version metadata also tracked in pbxproj build settings, the four
# values can drift on a marketing-version bump that touches one but not
# the other. Last drift produced "extension '1.0' must match parent app
# ('0.1.0')" build warnings.
#
# Behavior: exits 0 when all 4 SHORT_VERSION values agree AND all 4
# CFBUNDLE_VERSION values agree; non-zero otherwise with a clear
# diff-style report.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PBX="Stir.xcodeproj/project.pbxproj"
APP_PLIST="Stir/App/Info.plist"
SHARE_PLIST="Extensions/StirShareExtension/Info.plist"
WIDGETS_PLIST="Extensions/StirWidgets/Info.plist"

# Collect distinct MARKETING_VERSION values from pbxproj. Six configs
# (Debug+Release × {main app, share extension, widgets}) all should
# agree.
PBX_MV="$(grep -E '^[[:space:]]+MARKETING_VERSION = ' "$PBX" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | sort -u)"
PBX_CV="$(grep -E '^[[:space:]]+CURRENT_PROJECT_VERSION = ' "$PBX" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/' | sort -u)"

# /usr/libexec/PlistBuddy is the canonical Info.plist reader on macOS.
PB() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

APP_SV="$(PB CFBundleShortVersionString "$APP_PLIST")"
SHARE_SV="$(PB CFBundleShortVersionString "$SHARE_PLIST")"
WIDGETS_SV="$(PB CFBundleShortVersionString "$WIDGETS_PLIST")"

APP_BV="$(PB CFBundleVersion "$APP_PLIST")"
SHARE_BV="$(PB CFBundleVersion "$SHARE_PLIST")"
WIDGETS_BV="$(PB CFBundleVersion "$WIDGETS_PLIST")"

# Plists may either (a) hold the literal value (must match pbxproj) or
# (b) hold the `$(VAR)` substitution token (Xcode resolves at build
# time from pbxproj). Treat $(VAR) as "resolves to pbxproj value".
normalize() {
    local raw="$1" pbx_value="$2"
    case "$raw" in
        '$(MARKETING_VERSION)'|'$(CURRENT_PROJECT_VERSION)') echo "$pbx_value" ;;
        *) echo "$raw" ;;
    esac
}

APP_SV_N="$(normalize "$APP_SV" "$PBX_MV")"
SHARE_SV_N="$(normalize "$SHARE_SV" "$PBX_MV")"
WIDGETS_SV_N="$(normalize "$WIDGETS_SV" "$PBX_MV")"
APP_BV_N="$(normalize "$APP_BV" "$PBX_CV")"
SHARE_BV_N="$(normalize "$SHARE_BV" "$PBX_CV")"
WIDGETS_BV_N="$(normalize "$WIDGETS_BV" "$PBX_CV")"

ALL_SV="$(printf '%s\n' "$PBX_MV" "$APP_SV_N" "$SHARE_SV_N" "$WIDGETS_SV_N" | sort -u)"
ALL_BV="$(printf '%s\n' "$PBX_CV" "$APP_BV_N" "$SHARE_BV_N" "$WIDGETS_BV_N" | sort -u)"

SV_COUNT="$(printf '%s\n' "$ALL_SV" | grep -c .)"
BV_COUNT="$(printf '%s\n' "$ALL_BV" | grep -c .)"

if [ "$SV_COUNT" = "1" ] && [ "$BV_COUNT" = "1" ]; then
    echo "[version-sync] ✅ MARKETING_VERSION=$ALL_SV  CURRENT_PROJECT_VERSION=$ALL_BV"
    exit 0
fi

echo "[version-sync] ❌ version drift detected — TestFlight upload will reject"
echo
printf '  pbxproj MARKETING_VERSION:        %s\n' "$PBX_MV"
printf '  Stir/App/Info.plist short:        %s\n' "$APP_SV"
printf '  StirShareExtension short:         %s\n' "$SHARE_SV"
printf '  StirWidgets short:                %s\n' "$WIDGETS_SV"
echo
printf '  pbxproj CURRENT_PROJECT_VERSION:  %s\n' "$PBX_CV"
printf '  Stir/App/Info.plist version:      %s\n' "$APP_BV"
printf '  StirShareExtension version:       %s\n' "$SHARE_BV"
printf '  StirWidgets version:              %s\n' "$WIDGETS_BV"
echo
echo "  fix: bump all four together. The pbxproj entries set the build"
echo "  setting; the plist literals are what end up in the bundle."
exit 1
