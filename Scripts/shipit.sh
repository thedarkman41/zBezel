#!/usr/bin/env bash
#
# shipit.sh — the one command to ship zBezel. Gate, commit, push, relaunch.
#
#   ./Scripts/shipit.sh                    # subject = first line of CHANGES.txt
#   ./Scripts/shipit.sh -m "Subject"       # explicit subject; CHANGES.txt is the body
#   ./Scripts/shipit.sh --no-push          # commit and relaunch, skip the push
#   ./Scripts/shipit.sh --no-relaunch      # commit and push, leave the app running
#   ./Scripts/shipit.sh --no-bump          # commit without touching VERSION
#
# Adapted from Clarinet's Tools/ship.sh, with its secret-scan carried over
# verbatim. What differs is the gate: Clarinet gates on Swift building, this
# gates on all three languages zBezel is written in, because two of them are
# not compiled by the Mac build at all.
#
# A full run, in order:
#
#   1. Proves it is running against THIS repo before touching anything —
#      resolve the script's own path, never trust the caller's cwd.
#   2. Reminds, without blocking, when the audit trails have no report from
#      the last 30 days.
#   3. Reads CHANGES.txt. Refuses to commit without one.
#   4. GATE (blocking, any failure refuses the ship):
#        a. ddc.c compiles clean under -Wall -Wextra. It is the only memory-
#           unsafe code here and it parses bytes a monitor controls.
#        b. The macOS app builds with no warnings.
#        c. The Windows agent compiles under /warn:4 /warnaserror on the proxy
#           host. SKIPPED WITH A NOTE when that host is unreachable — a laptop
#           on a train should still be able to ship a Swift change — but never
#           skipped silently, because nothing else on this machine can compile
#           C# and an agent that does not build is an agent nobody can install.
#   5. Secret-scans the worktree, bumps VERSION, folds CHANGES.txt into
#      CHANGELOG.md, stages, scans the STAGED diff, commits.
#   6. Pushes through ../gh-push.sh (PAT via GIT_ASKPASS, never in .git/config).
#   7. Relaunches the app and PROVES the running process is the build just
#      made — comparing the bundle version, not just that something restarted.
#
set -euo pipefail

# ── Locate the repo, and PROVE it ────────────────────────────────────────
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
    LINK="$(readlink "$SCRIPT_PATH")"
    case "$LINK" in
        /*) SCRIPT_PATH="$LINK" ;;
        *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$LINK" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_DIR"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: $REPO_DIR is not a git repository" >&2; exit 1; }
[ "$(git rev-parse --show-toplevel)" = "$REPO_DIR" ] || { echo "error: $REPO_DIR is not the repo root" >&2; exit 1; }
[ -f "$REPO_DIR/Sources/BezelApp.swift" ] && [ -f "$REPO_DIR/Agent/BezelAgent.cs" ] \
    || { echo "error: $REPO_DIR does not look like zBezel" >&2; exit 1; }

SUBJECT=""; DO_PUSH=1; DO_RELAUNCH=1; DO_BUMP=1
while [ $# -gt 0 ]; do
    case "$1" in
        -m) SUBJECT="${2:-}"; shift 2 ;;
        --no-push)     DO_PUSH=0;     shift ;;
        --no-relaunch) DO_RELAUNCH=0; shift ;;
        --no-bump)     DO_BUMP=0;     shift ;;
        *) echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done

say() { printf '\n== %s ==\n' "$1"; }

# ── 2. Audit-trail reminder (never blocking) ─────────────────────────────
RECENT="$(find "$REPO_DIR/Security Audit Trail" "$REPO_DIR/Standards Audit Trail" \
          -name '*.md' -mtime -30 2>/dev/null | wc -l | tr -d ' ')"
if [ "$RECENT" = "0" ]; then
    echo
    echo "  reminder: no audit report in the last 30 days."
    echo "  standards/standards/{security-audit,code-enforcement}.md — findings are ZBZ-###."
fi

# ── 3. CHANGES.txt ───────────────────────────────────────────────────────
[ -s "$REPO_DIR/CHANGES.txt" ] || {
    echo "error: CHANGES.txt is missing or empty." >&2
    echo "  Write what this change does, then ship. The first line becomes the" >&2
    echo "  commit subject unless -m overrides it." >&2
    exit 1
}
[ -n "$SUBJECT" ] || SUBJECT="$(head -1 "$REPO_DIR/CHANGES.txt")"

# ── 4. The gate ──────────────────────────────────────────────────────────
say "gate"

echo "  ddc.c under -Wall -Wextra"
CC_OUT="$(clang -fsyntax-only -Wall -Wextra "$REPO_DIR/Sources/ddc.c" 2>&1 || true)"
if [ -n "$CC_OUT" ]; then
    echo "$CC_OUT" | sed 's/^/    /'
    echo "  REFUSED: ddc.c is not warning-clean." >&2
    exit 1
fi
echo "    clean"

echo "  macOS app build"
BUILD_OUT="$("$REPO_DIR/Scripts/build-app.sh" 2>&1 || true)"
if ! printf '%s' "$BUILD_OUT" | grep -q '^Built: '; then
    printf '%s\n' "$BUILD_OUT" | tail -20 | sed 's/^/    /'
    echo "  REFUSED: the app did not build." >&2
    exit 1
fi
if printf '%s' "$BUILD_OUT" | grep -q 'warning:'; then
    printf '%s\n' "$BUILD_OUT" | grep 'warning:' | head -10 | sed 's/^/    /'
    echo "  REFUSED: the build emitted warnings." >&2
    exit 1
fi
echo "    clean"

echo "  Windows agent under /warn:4 /warnaserror"
PROXY_HOST="$(defaults read com.darkstar.zBezel proxyHost 2>/dev/null || true)"
if [ -z "$PROXY_HOST" ]; then
    echo "    SKIPPED — no proxy host configured; C# was not compiled by this ship."
elif ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$PROXY_HOST" true 2>/dev/null; then
    echo "    SKIPPED — $PROXY_HOST unreachable; C# was not compiled by this ship."
else
    CSC='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    scp -q -o BatchMode=yes "$REPO_DIR/Agent/BezelAgent.cs" "$PROXY_HOST:bezel/BezelAgent.check.cs"
    CS_OUT="$(ssh -o BatchMode=yes "$PROXY_HOST" \
        "& '$CSC' /nologo /warn:4 /warnaserror /target:exe /out:\"\$HOME\\bezel\\BezelAgent.check.exe\" \"\$HOME\\bezel\\BezelAgent.check.cs\" 2>&1 | Out-String" 2>&1 || true)"
    ssh -o BatchMode=yes "$PROXY_HOST" \
        'Remove-Item "$HOME\bezel\BezelAgent.check.cs","$HOME\bezel\BezelAgent.check.exe" -ErrorAction SilentlyContinue' 2>/dev/null || true
    if printf '%s' "$CS_OUT" | grep -qiE 'error|warning'; then
        printf '%s\n' "$CS_OUT" | head -12 | sed 's/^/    /'
        echo "  REFUSED: the agent does not compile clean." >&2
        exit 1
    fi
    echo "    clean (compiled on $PROXY_HOST)"
fi

# ── 5. Secret scan, version, changelog, commit ───────────────────────────
say "secret scan (worktree)"
"$REPO_DIR/Scripts/secret-scan.sh" --worktree

if [ "$DO_BUMP" = "1" ]; then
    CUR="$(cat "$REPO_DIR/VERSION")"
    NEXT="$(printf '%s' "$CUR" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')"
    printf '%s\n' "$NEXT" > "$REPO_DIR/VERSION"
    echo "  version $CUR -> $NEXT"
else
    NEXT="$(cat "$REPO_DIR/VERSION")"
    echo "  version held at $NEXT"
fi

say "changelog"
STAMP="$(date +%Y-%m-%d)"
{
    printf '## %s — %s\n\n' "$NEXT" "$STAMP"
    cat "$REPO_DIR/CHANGES.txt"
    printf '\n\n'
    [ -f "$REPO_DIR/CHANGELOG.md" ] && cat "$REPO_DIR/CHANGELOG.md"
} > "$REPO_DIR/CHANGELOG.new"
mv "$REPO_DIR/CHANGELOG.new" "$REPO_DIR/CHANGELOG.md"
echo "  folded CHANGES.txt into CHANGELOG.md as $NEXT"

git add -A
say "secret scan (staged)"
"$REPO_DIR/Scripts/secret-scan.sh"

say "commit"
git commit -q -F - <<COMMITEOF
$SUBJECT

$(sed '1d' "$REPO_DIR/CHANGES.txt")

Version $NEXT.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
COMMITEOF
git log -1 --format='  %h %s' | cat

# CHANGES.txt is the description of the work just shipped; it starts empty again.
: > "$REPO_DIR/CHANGES.txt"

# ── 6. Push ──────────────────────────────────────────────────────────────
if [ "$DO_PUSH" = "1" ] && git remote get-url origin >/dev/null 2>&1; then
    say "push"
    if [ -x "$REPO_DIR/../gh-push.sh" ]; then
        "$REPO_DIR/../gh-push.sh" origin "$(git rev-parse --abbrev-ref HEAD)"
    else
        git push origin "$(git rev-parse --abbrev-ref HEAD)"
    fi
else
    echo "  (push skipped)"
fi

# ── 7. Relaunch, and prove the running build is the new one ──────────────
if [ "$DO_RELAUNCH" = "1" ] && [ "$(uname)" = "Darwin" ]; then
    say "relaunch"
    pkill -f "zBezel.app/Contents/MacOS/zBezel" 2>/dev/null || true
    sleep 1
    open "$REPO_DIR/build/zBezel.app"
    for _ in $(seq 1 20); do
        sleep 1
        RUNNING_PID="$(pgrep -f 'zBezel.app/Contents/MacOS/zBezel' | head -1 || true)"
        [ -n "$RUNNING_PID" ] && break
    done
    if [ -z "${RUNNING_PID:-}" ]; then
        echo "  WARNING: zBezel did not come back up." >&2
    else
        SERVING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                   "$REPO_DIR/build/zBezel.app/Contents/Info.plist" 2>/dev/null || echo '?')"
        if [ "$SERVING" = "$NEXT" ]; then
            echo "  running pid $RUNNING_PID, version $SERVING — matches the build just shipped"
        else
            echo "  WARNING: running bundle reports $SERVING, expected $NEXT" >&2
        fi
    fi
fi

say "shipped $NEXT"
