#!/bin/sh
#
# gowin_cli_fix_macos.sh
# -----------------------------------------------------------------------------
# Make Gowin's command-line tools (gw_sh, GowinSynthesis, etc.) runnable on
# macOS WITHOUT sudo and WITHOUT the full GUI fixer.
#
# WHY THIS IS NEEDED
#   Recent Gowin macOS builds correctly link the GUI binary (gw_ide), but still
#   ship the command-line / engine binaries with three broken dynamic-link
#   references that stop `gw_sh` from running headless:
#
#     1. RPATH uses the literal, unexpanded `$ORIGIN` instead of
#        `@executable_path/../lib`  -> libGWTE.dylib etc. fail to load.
#     2. Tcl is hardcoded to /Library/Frameworks/Tcl.framework/... instead of
#        the copy bundled in IDE/lib.
#     3. libcrypto is hardcoded to a Homebrew openssl@3 path instead of the
#        copy bundled in IDE/lib. (Often masked: only fails if Homebrew's
#        openssl@3 is absent or version-bumped.)
#
#   All three target libraries ARE bundled in IDE/lib, so the fix just redirects
#   the references there. This is the *linking* subset of the classic
#   gowin_eda_mac_fixer.sh, minus the parts that aren't needed for CLI builds:
#     - quarantine removal (xattr -cr)   -> needs sudo; only matters for GUI
#                                            launch via Gatekeeper, not for a
#                                            piped CLI subprocess.
#     - Assistant codesign / GUI rpaths  -> help viewer only.
#
# REQUIREMENTS
#   - The Gowin app must be owned by your user (the default for a normal
#     install), so no sudo is required to patch the binaries.
#   - Xcode Command Line Tools (`install_name_tool`, `codesign`, `otool`).
#
# USAGE
#   tools/gowin_cli_fix_macos.sh [path-to-IDE-dir]
#
#   Default IDE dir:
#     /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
#
#   Safe to re-run: every step is a no-op if already applied, so this also
#   doubles as a check — if it reports "nothing to fix", a future Gowin build
#   has fixed the CLI tools and this script is no longer required.
# -----------------------------------------------------------------------------

set -eu

IDE="${1:-/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE}"
BIN="$IDE/bin"
LIB="$IDE/lib"

OLD_RPATH='$ORIGIN:$ORIGIN/../lib'
NEW_RPATH='@executable_path/../lib'
OLD_TCL='/Library/Frameworks/Tcl.framework/Versions/8.6/Tcl'
NEW_TCL='@rpath/Tcl.framework/Versions/8.6/Tcl'
OLD_CRYPTO='/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib'
NEW_CRYPTO='@rpath/libcrypto.3.dylib'

[ -d "$IDE" ] || { echo "ERROR: Gowin IDE dir not found: $IDE" >&2; exit 1; }
command -v install_name_tool >/dev/null 2>&1 || {
    echo "ERROR: install_name_tool not found (install Xcode Command Line Tools)" >&2; exit 1; }

[ -e "$LIB/Tcl.framework/Versions/8.6/Tcl" ] || \
    echo "WARN: bundled Tcl.framework not found in $LIB (@rpath redirect may not resolve)" >&2
[ -e "$LIB/libcrypto.3.dylib" ] || \
    echo "WARN: bundled libcrypto.3.dylib not found in $LIB (@rpath redirect may not resolve)" >&2

changed=0

# True if Mach-O file $1 has an LC_RPATH entry exactly equal to $2.
has_rpath() {
    otool -l "$1" 2>/dev/null | awk '/LC_RPATH/{r=1;next} r&&/ path /{print $2;r=0}' \
        | grep -qxF "$2"
}

# Dependency / framework references of Mach-O file $1 (one path per line).
refs() { otool -L "$1" 2>/dev/null | awk 'NR>1{print $1}'; }

# Patch one Mach-O file. $2 = "exe" to also rewrite RPATH ($ORIGIN issue).
fix_file() {
    f="$1"; kind="$2"
    [ -f "$f" ] || return 0
    file "$f" 2>/dev/null | grep -q "Mach-O" || return 0

    fchanged=0

    if [ "$kind" = "exe" ] && has_rpath "$f" "$OLD_RPATH"; then
        has_rpath "$f" "$NEW_RPATH" || install_name_tool -add_rpath "$NEW_RPATH" "$f"
        install_name_tool -delete_rpath "$OLD_RPATH" "$f"
        fchanged=1
    fi
    if refs "$f" | grep -qxF "$OLD_TCL"; then
        install_name_tool -change "$OLD_TCL" "$NEW_TCL" "$f"; fchanged=1
    fi
    if refs "$f" | grep -qxF "$OLD_CRYPTO"; then
        install_name_tool -change "$OLD_CRYPTO" "$NEW_CRYPTO" "$f"; fchanged=1
    fi

    if [ "$fchanged" = 1 ]; then
        # Editing a Mach-O invalidates its ad-hoc signature on arm64; re-sign.
        codesign -f -s - "$f" >/dev/null 2>&1 || \
            echo "  WARN: could not re-sign $(basename "$f")" >&2
        echo "  fixed:   $(basename "$f")"
        changed=$((changed + 1))
    fi
}

echo "Gowin CLI link fixer"
echo "  IDE: $IDE"
echo

echo "==> Executables ($BIN)"
for f in "$BIN"/*; do
    fix_file "$f" exe
done

echo "==> Bundled libraries ($LIB and plugins/ide)"
for f in "$LIB"/*.dylib "$IDE"/plugins/ide/*.dylib; do
    fix_file "$f" lib
done

echo
if [ "$changed" -eq 0 ]; then
    echo "Nothing to fix — the CLI tools are already correctly linked."
    echo "(If this is a fresh install, Gowin may have fixed it upstream.)"
else
    echo "Patched $changed file(s)."
fi

echo
echo "==> Verifying gw_sh and GowinSynthesis no longer reference broken paths"
for b in gw_sh GowinSynthesis; do
    f="$BIN/$b"
    [ -f "$f" ] || continue
    bad=$(refs "$f" | grep -E "/Library/Frameworks/Tcl|/opt/homebrew/.*libcrypto" || true)
    rp=$(has_rpath "$f" "$OLD_RPATH" && echo "BROKEN(\$ORIGIN)" || echo "ok")
    if [ -z "$bad" ] && [ "$rp" = "ok" ]; then
        echo "  $b: OK"
    else
        echo "  $b: still has issues -> rpath=$rp ${bad:+badrefs=$bad}"
    fi
done

echo
echo "Done. Test with:"
echo "  cd boards/<board> && printf 'open_project <board>.gprj\\nrun syn\\nexit\\n' | $BIN/gw_sh"
