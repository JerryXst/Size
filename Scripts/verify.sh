#!/bin/bash
# Runs every check the project has, in order of how much they cost.
#
#   0. package + signature sanity
#   1. unit tests              pure geometry, config and hotkey logic
#   2. selftest                every action applied to a throwaway window
#   3. hotkeytest              a real key event drives the running app
#   4. uitest                  the settings window opens and has controls
#
# Steps 3 and 4 need Size.app running with Accessibility permission.
#
# Note on implementation: every command writes to a log file and the checks grep
# that file. Piping directly into `grep -q` would make grep exit early, send
# SIGPIPE to the producer, and `set -o pipefail` would then report a failure for
# a test that actually passed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/size-cli"
APP="$ROOT/build/Size.app"
LOGDIR="$ROOT/build/verify"
mkdir -p "$LOGDIR"
FAILED=0

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
info() { printf '       %s\n' "$1"; }

# run <log-name> <command...>: capture combined output, return the exit status.
run() {
    local name="$1"
    shift
    "$@" >"$LOGDIR/$name.log" 2>&1
    return $?
}

step "0/5  Package and signature"
if run build swift build --package-path "$ROOT"; then
    pass "swift build"
else
    fail "swift build"
    tail -20 "$LOGDIR/build.log" | sed 's/^/       /'
    exit 1
fi

if [ -d "$APP" ]; then
    run codesign codesign --verify --verbose=1 "$APP"
    if [ $? -eq 0 ]; then
        pass "code signature is valid on disk"
    else
        fail "code signature"
        tail -5 "$LOGDIR/codesign.log" | sed 's/^/       /'
    fi

    # A revoked certificate is what makes Gatekeeper call the app malware.
    run spctl spctl --assess --type execute "$APP"
    if grep -q "CSSMERR_TP_CERT_REVOKED" "$LOGDIR/spctl.log"; then
        fail "signing certificate is REVOKED — run Scripts/make-signing-identity.sh"
    else
        info "Gatekeeper assessment: $(tail -1 "$LOGDIR/spctl.log" | sed 's/^[^:]*: //')"
    fi

    INSTANCES=$(pgrep -f "$APP/Contents/MacOS/Size" | wc -l | tr -d ' ')
    if [ "$INSTANCES" -eq 1 ]; then
        pass "exactly one app instance running"
    elif [ "$INSTANCES" -eq 0 ]; then
        info "app is not running (steps 3 and 4 will fail; run: open \"$APP\")"
    else
        fail "$INSTANCES app instances running — hotkeys will land on the wrong one"
    fi
else
    info "no app bundle yet (run Scripts/build-app.sh for steps 3 and 4)"
fi

step "1/5  Unit tests"
run test swift test --package-path "$ROOT"
SUMMARY=$(grep -oE 'Executed [0-9]+ tests, with [0-9]+ failures' "$LOGDIR/test.log" | tail -1)
if grep -q "with 0 failures" "$LOGDIR/test.log" && ! grep -q "error:" "$LOGDIR/test.log"; then
    pass "${SUMMARY:-unit tests}"
else
    fail "${SUMMARY:-unit tests}"
    grep -E "error:|XCTAssert.*failed" "$LOGDIR/test.log" | head -10 | sed 's/^/       /'
fi

step "2/5  End-to-end actions (throwaway window)"
# macOS refuses cross-application Accessibility access while the screen is locked,
# so the window steps cannot run — say so instead of reporting a bogus failure.
SCREEN_LOCKED=0
# Note: write to a file first. Piping ioreg into `grep -q` would let grep exit on
# the first match, kill ioreg with SIGPIPE, and `set -o pipefail` would then
# report "not locked" even when it is.
ioreg -n Root -d1 >"$LOGDIR/ioreg.log" 2>/dev/null
if grep -q 'CGSSessionScreenIsLocked.*Yes' "$LOGDIR/ioreg.log"; then
    SCREEN_LOCKED=1
fi
if [ "$SCREEN_LOCKED" -eq 1 ]; then
    info "screen is locked — skipping window checks (2/5, 3/5, 4/5)"
    info "unlock the Mac and re-run: bash Scripts/verify.sh"
    printf '\n'
    if [ "$FAILED" -eq 0 ]; then
        printf '\033[33mPassed what could run while locked; unlock and re-run for the rest.\033[0m\n'
    else
        printf '\033[31mSome checks failed.\033[0m\n'
    fi
    exit "$FAILED"
fi

pkill -f size-testhost 2>/dev/null
run selftest "$CLI" selftest
if grep -q "All self-tests passed" "$LOGDIR/selftest.log"; then
    pass "all actions applied correctly"
else
    fail "selftest"
    tail -20 "$LOGDIR/selftest.log" | sed 's/^/       /'
fi

step "3/5  Real key event"
pkill -f size-testhost 2>/dev/null
run hotkeytest "$CLI" hotkeytest
if grep -q "Hotkey test passed" "$LOGDIR/hotkeytest.log"; then
    pass "app responded to ⌃⌥← and ⌃⌥⌫"
else
    fail "hotkeytest (is Size.app running with Accessibility permission?)"
    tail -8 "$LOGDIR/hotkeytest.log" | sed 's/^/       /'
fi

step "4/5  Settings window"
run uitest "$CLI" uitest
if grep -q "UI test passed" "$LOGDIR/uitest.log"; then
    pass "settings window opens with controls"
else
    fail "uitest"
    tail -8 "$LOGDIR/uitest.log" | sed 's/^/       /'
fi

step "5/5  Cleanup"
# A previous uitest run toggled "launch at login" and left a LaunchAgent behind,
# which made launchd respawn the app and produce duplicate instances.
# `launchctl list` prints "PID\tStatus\tLabel"; while Size.app is running
# its *launchd job* shows up as application.com.jerryxst.size.<gen>, which
# a plain substring grep matched and reported as stale. Match the exact
# label instead — steps 3/4 need the app running, so the old check could
# never pass at the same time.
if launchctl list 2>/dev/null | grep -qE '[[:space:]]com\.jerryxst\.size$'; then
    fail "stale LaunchAgent com.jerryxst.size — run: launchctl bootout gui/$(id -u)/com.jerryxst.size"
else
    pass "no stale LaunchAgent"
fi
pkill -f size-testhost 2>/dev/null

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mAll checks passed.\033[0m\n'
    exit 0
else
    printf '\033[31mSome checks failed.\033[0m\n'
    exit 1
fi
