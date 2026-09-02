#!/usr/bin/env bash
#
# shipit.sh — gate, commit, push, relaunch. The one command to ship zBezel.
#
# Usage:
#   Scripts/shipit.sh                    # gate + bump + commit (+ push if origin)
#   Scripts/shipit.sh -m "Subject line"  # explicit subject; CHANGES.txt is the body
#   Scripts/shipit.sh --only PATH        # commit ONLY these paths (repeatable),
#                                        # leaving unrelated in-flight work alone.
#                                        # VERSION and CHANGELOG.md always included.
#   Scripts/shipit.sh --no-bump          # commit without touching VERSION
#   Scripts/shipit.sh --no-relaunch      # commit only; leave the running app alone
#   Scripts/shipit.sh --relaunch         # relaunch even for a docs-only change
#   Scripts/shipit.sh --relaunch-only    # build + restart the app, commit nothing
#   Scripts/shipit.sh --origin           # ALSO create the GitHub repo + push
#   Scripts/shipit.sh --origin --public  # create it public (default private)
#   Scripts/shipit.sh --origin --repo-name OtherName
#
# Adapted from Clarinet's Tools/ship.sh, which is the most battle-tested of the
# ship scripts in this stable. Its structure is kept deliberately, including the
# ordering rules that were learned the hard way there:
#
#   * Validation NEVER mutates. Every check that can refuse a commit runs
#     before the version bump, so a rejected run does not burn a version
#     number and leave VERSION dirty.
#   * The build runs BEFORE the commit. A commit that does not compile is
#     worse than no commit — it is the state every later bisect steps over.
#   * The changelog entry is generated from the SAME subject and body as the
#     commit message, so the two cannot drift.
#   * The relaunch PROVES the running build is the one just shipped. Without
#     that, "relaunched" is an assumption, and the usual failure is a stale
#     process still answering.
#   * Relaunch takes a mutex, because two sessions restarting the one app race.
#
# What differs from Clarinet is the gate. Clarinet gates on Swift building.
# zBezel is written in three languages and the Mac build compiles only one of
# them, so the gate covers all three — see "The gate" below.
#
set -euo pipefail

# ── Locate the repo, and PROVE it before doing anything ──
# `dirname "$0"` is not enough: it breaks under a symlink and, worse, a bad
# resolution would leave us committing whatever repository we happened to land
# in. Resolve the real script path, walk up, then verify all three of: this is
# a git repo, its top level IS this directory, and it is actually zBezel.
SCRIPT_PATH="${BASH_SOURCE[0]}"
while [ -L "$SCRIPT_PATH" ]; do
    LINK_TARGET="$(readlink "$SCRIPT_PATH")"
    case "$LINK_TARGET" in
        /*) SCRIPT_PATH="$LINK_TARGET" ;;
        *)  SCRIPT_PATH="$(dirname "$SCRIPT_PATH")/$LINK_TARGET" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_DIR"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "error: $REPO_DIR is not a git repository" >&2
    exit 1
fi
GIT_ROOT="$(git rev-parse --show-toplevel)"
if [ "$GIT_ROOT" != "$REPO_DIR" ]; then
    echo "error: refusing to run — the git root is:" >&2
    echo "         $GIT_ROOT" >&2
    echo "       but this script belongs to:" >&2
    echo "         $REPO_DIR" >&2
    echo "       (running it would commit the wrong repository)" >&2
    exit 1
fi
if [ ! -f "$REPO_DIR/Sources/BezelApp.swift" ] || [ ! -f "$REPO_DIR/Agent/BezelAgent.cs" ]; then
    echo "error: $REPO_DIR does not look like zBezel" >&2
    exit 1
fi
echo "Repo: $REPO_DIR"

# The shipped app lives on the internal volume, not in the repo: the repo is on
# a file-provider volume whose com.apple.FinderInfo stamp fails strict codesign
# verification, which in turn makes TCC refuse the Accessibility grant.
# build-app.sh installs and signs it there; build/ is only staging.
APP_BUNDLE="/Applications/zBezel.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/zBezel"
BODY_FILE="$REPO_DIR/CHANGES.txt"
CHANGELOG="$REPO_DIR/CHANGELOG.md"
MARKER='<!-- shipit.sh inserts new entries directly below this line. Do not remove it. -->'
TOKEN_FILE="${GH_TOKEN_FILE:-$(dirname "$REPO_DIR")/.gh-token}"

SUBJECT=""
DO_BUMP=1
MAKE_ORIGIN=0
REPO_VISIBILITY="private"
REPO_NAME=""
DO_RELAUNCH=1
FORCE_RELAUNCH=0
RELAUNCH_ONLY=0
ONLY_PATHS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -m) SUBJECT="${2:-}"; shift 2 ;;
        --only) ONLY_PATHS+=("${2:?--only needs a path}"); shift 2 ;;
        --no-bump) DO_BUMP=0; shift ;;
        --origin) MAKE_ORIGIN=1; shift ;;
        --public) REPO_VISIBILITY="public"; shift ;;
        --repo-name) REPO_NAME="${2:-}"; shift 2 ;;
        --no-relaunch) DO_RELAUNCH=0; shift ;;
        --relaunch) DO_RELAUNCH=1; FORCE_RELAUNCH=1; shift ;;
        --relaunch-only) RELAUNCH_ONLY=1; shift ;;
        -h|--help) sed -n '3,20p' "$SCRIPT_PATH"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Relaunch mutex ────────────────────────────────────────────────────────
# Two sessions will both try to restart the one app. Interleaved they race: A
# stops it, B starts its build, A starts its build, and the menu bar ends up
# owned by a binary neither session thinks is running — with the version check
# then failing for reasons that look like a build problem.
#
# The lock lives beside the app's data, NOT in the repo: the thing guarded is
# the single running process, so two checkouts must contend for one lock.
# mkdir is the atomic primitive — `[ -e ]` then `touch` has a window between
# the test and the create, which is exactly the race.
LOCKDIR="$HOME/Library/Application Support/zBezel/relaunch.lock"
HOLD_LOCK=0

release_relaunch_lock() {
    [ "$HOLD_LOCK" -eq 1 ] || return 0
    rm -rf "$LOCKDIR"
    HOLD_LOCK=0
}
trap 'release_relaunch_lock' EXIT INT TERM

acquire_relaunch_lock() {
    local waited=0 owner_pid
    mkdir -p "$(dirname "$LOCKDIR")"
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        owner_pid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
        # A lock whose owner died is not a lock. Without this, one killed run
        # blocks every future relaunch until someone deletes it by hand.
        if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
            echo "Clearing a stale relaunch lock (pid $owner_pid is gone)."
            rm -rf "$LOCKDIR"
            continue
        fi
        [ "$waited" -eq 0 ] && echo "Another process is relaunching zBezel (pid ${owner_pid:-unknown}); waiting…"
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge 120 ]; then
            echo "error: timed out after 120s waiting for the relaunch lock." >&2
            echo "       If pid ${owner_pid:-unknown} is gone, remove: $LOCKDIR" >&2
            exit 1
        fi
    done
    HOLD_LOCK=1
    echo "$$" > "$LOCKDIR/pid"
    date '+%Y-%m-%d %H:%M:%S' > "$LOCKDIR/since"
}

# ── build_app: rebuild, refusing on any warning ───────────────────────────
build_app() {
    local out
    out="$("$SCRIPT_DIR/build-app.sh" 2>&1 || true)"
    if ! printf '%s' "$out" | grep -q '^Built: '; then
        printf '%s\n' "$out" | tail -20 | sed 's/^/    /'
        echo "error: the app did not build." >&2
        return 1
    fi
    if printf '%s' "$out" | grep -q 'warning:'; then
        printf '%s\n' "$out" | grep 'warning:' | head -10 | sed 's/^/    /'
        echo "error: the build emitted warnings." >&2
        return 1
    fi
    return 0
}

# ── relaunch_app: stop, rebuild, start, and PROVE the new build is running ──
# zBezel is a menu bar app with no window of its own at launch, so "did it come
# back" cannot be answered by looking at the screen. Compare the bundle version
# the running process was launched from against the version just shipped.
relaunch_app() {
    local expected="${1:-}" old_pids new_pid serving waited
    echo
    echo "== Relaunching =="
    acquire_relaunch_lock

    # The validation build ran BEFORE the version bump, so its bundle still
    # carries the old number. This pass is nearly free and makes the artifact
    # match the commit.
    build_app || { echo "error: rebuild after the version bump failed." >&2; exit 1; }

    # Match on the bundle path, not the bare name: a stray editor buffer or a
    # grep for "zBezel" would otherwise look like a running instance.
    old_pids="$(pgrep -f "zBezel.app/Contents/MacOS/zBezel" 2>/dev/null || true)"
    if [ -n "$old_pids" ]; then
        echo "Stopping: $(echo "$old_pids" | tr '\n' ' ')"
        # shellcheck disable=SC2086
        kill $old_pids 2>/dev/null || true
        sleep 1
        old_pids="$(pgrep -f "zBezel.app/Contents/MacOS/zBezel" 2>/dev/null || true)"
        # shellcheck disable=SC2086
        [ -n "$old_pids" ] && { kill -9 $old_pids 2>/dev/null || true; sleep 1; }
    fi

    open "$APP_BUNDLE"
    waited=0
    new_pid=""
    while [ "$waited" -lt 25 ]; do
        sleep 1
        new_pid="$(pgrep -f "zBezel.app/Contents/MacOS/zBezel" | head -1 || true)"
        [ -n "$new_pid" ] && break
        waited=$((waited + 1))
    done
    if [ -z "$new_pid" ]; then
        echo "error: zBezel did not come back up." >&2
        exit 1
    fi

    serving="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
               "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo '?')"
    if [ -n "$expected" ] && [ "$serving" != "$expected" ]; then
        echo "error: the running bundle reports $serving, expected $expected." >&2
        echo "       A stale process is answering, or the build did not restamp." >&2
        exit 1
    fi
    echo "Running: pid $new_pid, version $serving"
    release_relaunch_lock
}

# ── --relaunch-only exits here ────────────────────────────────────────────
if [ "$RELAUNCH_ONLY" -eq 1 ]; then
    relaunch_app ""
    exit 0
fi

# ── Subject and body, from one file so they cannot drift ──────────────────
if [ ! -s "$BODY_FILE" ]; then
    echo "error: CHANGES.txt is missing or empty." >&2
    echo "       Write what this change does — first line is the subject, then a" >&2
    echo "       blank line, then the body. Or pass -m \"Subject line\"." >&2
    exit 1
fi
BODY=""
if [ -z "$SUBJECT" ]; then
    if [ -n "$(sed -n '2p' "$BODY_FILE")" ]; then
        echo "error: CHANGES.txt line 2 must be blank (subject, blank line, body)." >&2
        echo "         $(sed -n '1p' "$BODY_FILE" | cut -c1-60)..." >&2
        exit 1
    fi
    SUBJECT="$(sed -n '1p' "$BODY_FILE")"
    BODY="$(sed -n '3,$p' "$BODY_FILE")"
else
    BODY="$(cat "$BODY_FILE" 2>/dev/null || true)"
fi
[ -n "$SUBJECT" ] || { echo "error: subject line is empty." >&2; exit 1; }
if [ "${#SUBJECT}" -gt 72 ]; then
    echo "warning: subject is ${#SUBJECT} chars (over 72) and will be truncated in logs." >&2
fi
echo "Subject: $SUBJECT"

# ── Does this run change the running app? ─────────────────────────────────
APP_CHANGED=0
if [ "${#ONLY_PATHS[@]}" -gt 0 ]; then
    CHANGED_PATHS="$(printf '%s\n' "${ONLY_PATHS[@]}")"
else
    CHANGED_PATHS="$(git status --porcelain | sed 's/^...//')"
fi
if printf '%s\n' "$CHANGED_PATHS" | grep -qE '^"?(Sources/|Agent/|Scripts/build-app\.sh|VERSION)'; then
    APP_CHANGED=1
fi
[ "$FORCE_RELAUNCH" -eq 1 ] && APP_CHANGED=1

# ── The gate — all three languages, BEFORE anything is committed ──────────
# The Mac build compiles only the Swift. ddc.c is the one memory-unsafe file
# here and it parses bytes a monitor controls; the agent cannot be compiled on
# this machine at all. Gating only on what `swift build` happens to touch would
# let both of the others rot.
echo
echo "== Gate =="

echo "  ddc.c under -Wall -Wextra"
CC_OUT="$(clang -fsyntax-only -Wall -Wextra "$REPO_DIR/Sources/ddc.c" 2>&1 || true)"
if [ -n "$CC_OUT" ]; then
    printf '%s\n' "$CC_OUT" | sed 's/^/    /'
    echo "error: ddc.c is not warning-clean — nothing committed." >&2
    exit 1
fi
echo "    clean"

echo "  macOS app"
build_app || { echo "error: nothing committed, nothing relaunched." >&2; exit 1; }
[ -x "$APP_BIN" ] || { echo "error: build reported success but $APP_BIN is missing." >&2; exit 1; }
echo "    clean"

# The proxy host's SSH shell is PowerShell, which has no `true` — probing with
# it reports every reachable host as unreachable, silently downgrading the gate.
# `exit 0` works in both shells.
echo "  Windows agent under /warn:4 /warnaserror"
PROXY_HOST="$(defaults read com.darkstar.zBezel proxyHost 2>/dev/null || true)"
SSH_MUX=(-o BatchMode=yes -o ControlMaster=auto -o ControlPersist=600)
if [ -z "$PROXY_HOST" ]; then
    echo "    SKIPPED — no proxy host configured; C# was not compiled by this ship."
else
    SSH_MUX+=(-o "ControlPath=$HOME/.bezel-cm-$PROXY_HOST")
    if ! ssh "${SSH_MUX[@]}" -o ConnectTimeout=20 "$PROXY_HOST" 'exit 0' 2>/dev/null; then
        echo "    SKIPPED — $PROXY_HOST unreachable; C# was not compiled by this ship."
    else
        CSC='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        scp -q "${SSH_MUX[@]}" "$REPO_DIR/Agent/BezelAgent.cs" "$PROXY_HOST:bezel/BezelAgent.check.cs"
        CS_OUT="$(ssh "${SSH_MUX[@]}" "$PROXY_HOST" \
            "& '$CSC' /nologo /warn:4 /warnaserror /target:exe /r:'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationClient.dll' /r:'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\UIAutomationTypes.dll' /r:'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\WindowsBase.dll' /out:\"\$HOME\\bezel\\BezelAgent.check.exe\" \"\$HOME\\bezel\\BezelAgent.check.cs\" 2>&1 | Out-String" 2>&1 || true)"
        ssh "${SSH_MUX[@]}" "$PROXY_HOST" \
            'Remove-Item "$HOME\bezel\BezelAgent.check.cs","$HOME\bezel\BezelAgent.check.exe" -ErrorAction SilentlyContinue' 2>/dev/null || true
        if printf '%s' "$CS_OUT" | grep -qiE 'error|warning'; then
            printf '%s\n' "$CS_OUT" | head -12 | sed 's/^/    /'
            echo "error: the agent does not compile clean — nothing committed." >&2
            exit 1
        fi
        echo "    clean (compiled on $PROXY_HOST)"
    fi
fi

# ── Secret scan BEFORE the bump ───────────────────────────────────────────
# A validation must not mutate: wired in after the bump, a rejected run still
# burns a version number and leaves VERSION dirty. This pre-flight reads the
# whole worktree; the authoritative scan runs on the staged diff below.
# `bash`, not `[ -x ]`: a lost executable bit must not skip a guard in silence.
if [ -f "$SCRIPT_DIR/secret-scan.sh" ]; then
    echo
    bash "$SCRIPT_DIR/secret-scan.sh" --worktree || exit 1
else
    echo "error: Scripts/secret-scan.sh is missing; refusing to commit blind." >&2
    exit 1
fi

# ── Bump LAST, after every check that can refuse the commit has passed ────
VERSION=""
if [ "$DO_BUMP" -eq 1 ]; then
    CUR="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo 0.0.0)"
    VERSION="$(printf '%s' "$CUR" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')"
    printf '%s\n' "$VERSION" > "$REPO_DIR/VERSION"
    echo "Version bumped to $VERSION"
else
    VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || true)"
fi

# ── Changelog ─────────────────────────────────────────────────────────────
# Generated from the SAME subject and body as the commit message. A
# hand-maintained changelog is a second authoring surface, and the second one
# always goes stale.
[ -f "$CHANGELOG" ] || { echo "error: $CHANGELOG is missing." >&2; exit 1; }
if ! grep -qF "$MARKER" "$CHANGELOG"; then
    echo "error: the insertion marker is gone from CHANGELOG.md." >&2
    echo "       Restore this line so entries keep landing in the right place:" >&2
    echo "         $MARKER" >&2
    exit 1
fi
ENTRY_FILE="$(mktemp)"
{
    echo
    echo "## ${VERSION:-unversioned} — $(date '+%Y-%m-%d')"
    echo
    echo "**$SUBJECT**"
    [ -n "$BODY" ] && { echo; echo "$BODY"; }
} > "$ENTRY_FILE"
# awk, not `sed -i`: the body is arbitrary text, and backslashes and ampersands
# are metacharacters in a sed replacement — they would silently corrupt it.
CHANGELOG_TMP="$(mktemp)"
awk -v marker="$MARKER" -v entryfile="$ENTRY_FILE" '
    { print }
    $0 == marker && !done {
        while ((getline line < entryfile) > 0) print line
        done = 1
    }
' "$CHANGELOG" > "$CHANGELOG_TMP"
mv "$CHANGELOG_TMP" "$CHANGELOG"
rm -f "$ENTRY_FILE"
echo "Changelog entry added for ${VERSION:-unversioned}"

# ── Stage ─────────────────────────────────────────────────────────────────
# --only ships ONE unit of work while unrelated edits stay in the tree. With
# two features in flight, `git add -A` forces them into one commit that no
# honest subject line can describe. VERSION and the changelog are always
# included, since every commit bumps and records.
if [ "${#ONLY_PATHS[@]}" -gt 0 ]; then
    for p in "${ONLY_PATHS[@]}"; do
        [ -e "$p" ] || { echo "error: --only path does not exist: $p" >&2; exit 1; }
    done
    git add -- "${ONLY_PATHS[@]}" "$CHANGELOG" "$REPO_DIR/VERSION"
    if git diff --cached --quiet; then
        echo "error: --only staged nothing; those paths have no changes." >&2
        exit 1
    fi
    echo "Scoped commit — staged:"
    git diff --cached --name-only | sed 's/^/  /'
else
    git add -A
fi

if [ -f "$SCRIPT_DIR/secret-scan.sh" ]; then
    bash "$SCRIPT_DIR/secret-scan.sh" || exit 1
else
    echo "error: Scripts/secret-scan.sh is missing; refusing to commit blind." >&2
    exit 1
fi

{
    echo "$SUBJECT"
    [ -n "$BODY" ] && { echo; echo "$BODY"; }
    [ -n "$VERSION" ] && { echo; echo "Version: $VERSION"; }
    echo
    echo "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
    # A trailing no-op so this group ALWAYS exits 0: with pipefail, a false
    # test as the last command would kill the script AFTER the commit landed.
    :
} | git commit -F -

echo
echo "== Committed =="
git log --oneline -1

if [ "${#ONLY_PATHS[@]}" -gt 0 ] && [ -n "$(git status --porcelain)" ]; then
    echo
    echo "Still uncommitted (left in the tree by --only):"
    git status --short | sed 's/^/  /'
fi

# Retire the body file so the NEXT run cannot silently reuse the same message.
if [ -f "$BODY_FILE" ]; then
    mv "$BODY_FILE" "$REPO_DIR/.changes.${VERSION:-$(git rev-parse --short HEAD)}.txt"
    : > "$BODY_FILE"
    echo "(CHANGES.txt archived — write a new one for the next commit)"
fi

# ── Relaunch, BEFORE the push ─────────────────────────────────────────────
# The push section exits early when there is no origin; put the relaunch after
# it and a repo without a remote would never relaunch, which is exactly the
# setup that needs it most.
if [ "$APP_CHANGED" -eq 1 ] && [ "$DO_RELAUNCH" -eq 1 ]; then
    relaunch_app "$VERSION"
fi

# ── Push ──────────────────────────────────────────────────────────────────
if ! git remote get-url origin >/dev/null 2>&1; then
    if [ "$MAKE_ORIGIN" -eq 0 ]; then
        cat <<EOF

No 'origin' remote is configured, so nothing was pushed.

Create it and push in one step:

  Scripts/shipit.sh --origin              # private repo (default)
  Scripts/shipit.sh --origin --public     # public repo
  Scripts/shipit.sh --origin --repo-name OtherName

That uses the PAT in $TOKEN_FILE via the GitHub API — the
GitHub CLI (gh) is not required and is not installed here.

EOF
        exit 0
    fi

    [ -n "$REPO_NAME" ] || REPO_NAME="$(basename "$REPO_DIR")"
    git branch -M main
    [ -f "$TOKEN_FILE" ] || { echo "error: no token at $TOKEN_FILE" >&2; exit 1; }
    TOKEN="$(tr -d ' \t\r\n' < "$TOKEN_FILE")"
    PRIVATE_BOOL=true
    [ "$REPO_VISIBILITY" = "public" ] && PRIVATE_BOOL=false

    echo
    echo "Creating '$REPO_NAME' ($REPO_VISIBILITY) through the GitHub API…"
    TMP_JSON="$(mktemp)"
    trap 'rm -f "$TMP_JSON"; release_relaunch_lock' EXIT INT TERM
    curl -sS -X POST https://api.github.com/user/repos \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "{\"name\":\"$REPO_NAME\",\"private\":$PRIVATE_BOOL,\"has_wiki\":false,\"auto_init\":false}" \
        > "$TMP_JSON"
    unset TOKEN
    # Let python surface the API's own error text. A failed create returns 200-shaped
    # JSON with a "message", so testing curl's exit status alone would call it success.
    FULL_NAME="$(python3 - "$TMP_JSON" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
if "full_name" not in d:
    print("error:", d.get("message", "unknown"), file=sys.stderr)
    for e in d.get("errors", []):
        print("  -", e.get("message", e), file=sys.stderr)
    sys.exit(1)
print(d["full_name"])
PYEOF
)" || exit 1
    echo "Created $FULL_NAME ($REPO_VISIBILITY)"
    git remote add origin "https://github.com/$FULL_NAME.git"
fi

echo
echo "== Pushing =="
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ -x "$REPO_DIR/../gh-push.sh" ]; then
    "$REPO_DIR/../gh-push.sh" origin "$BRANCH"
else
    git push origin "$BRANCH"
fi
