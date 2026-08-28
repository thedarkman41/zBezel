#!/usr/bin/env bash
#
# secret-scan.sh — refuse a commit that stages a secret or a personal
# identifier. Run by ship.sh after staging and before `git commit`.
#
# Why this exists: zBezel commits its audit reports to the repo, and the first
# run, and the FIRST report this repository produced named the owner and
# their email in plain text while reporting that naming them was a finding.
# A rule that says "redact" is not a control. This is the control.
#
# Two classes are scanned, and they are found differently on purpose:
#
#   SECRETS are matched by SHAPE, with a length floor, so prose that merely
#   names a prefix ("look for sk-ant- keys") does not trip the scan while a
#   real key does. That is what lets the audit rubric and the trail keep
#   discussing the patterns they hunt for.
#
#   IDENTIFIERS are read from `git config` and the environment AT RUNTIME,
#   never hardcoded. Writing the owner's name into a tracked script to stop
#   the owner's name reaching tracked files would be the same bug wearing a
#   uniform.
#
# Only ADDED lines in the staged diff are scanned: what a commit introduces
# is what a commit is answerable for, and scanning whole files would flag
# history nobody is changing.
#
# Deliberate override, for the rare true positive that must land:
#   SKIP_SECRET_SCAN=1 Scripts/shipit.sh ...
#
set -euo pipefail

if [ "${SKIP_SECRET_SCAN:-0}" = "1" ]; then
    echo "secret-scan: SKIPPED by SKIP_SECRET_SCAN=1"
    exit 0
fi

# Added lines only.
#
# --output-indicator-new=@ rather than filtering out '^+++': that filter also
# ate every added line whose own text began with "++", which is a one-character
# way to walk a secret past this scan. With a distinct marker the file headers
# stay '+++' and cannot collide with content.
#
# --worktree scans everything not yet in HEAD, staged or not, plus untracked
# files. ship.sh runs it that way BEFORE bumping the version, so a hit costs no
# build number; the default staged scan is still the gate that guards the
# commit itself.
if [ "${1:-}" = "--worktree" ]; then
    ADDED="$(git diff HEAD --unified=0 --output-indicator-new=@ \
             | grep '^@' | grep -v '^@@' || true)"
    while IFS= read -r f; do
        [ -f "$f" ] && ADDED="$ADDED
$(sed 's/^/@/' -- "$f" 2>/dev/null || true)"
    done < <(git ls-files --others --exclude-standard)
else
    ADDED="$(git diff --cached --unified=0 --output-indicator-new=@ \
             | grep '^@' | grep -v '^@@' || true)"
fi
if [ -z "$ADDED" ]; then
    exit 0
fi

FAILED=0

report() {
    if [ "$FAILED" -eq 0 ]; then
        echo >&2
        echo "== secret-scan: staged content is not safe to commit ==" >&2
    fi
    FAILED=1
    echo >&2
    echo "  $1" >&2
    # Show WHERE, never WHAT. Printing the offending line would copy the
    # secret into the terminal, the scrollback, and any CI log.
    echo "  matched on $2 added line(s); run the grep below to see them:" >&2
    echo "    git diff --cached --unified=0 | grep -nE '$3'" >&2
}

# ── Secrets, matched by shape with a length floor ────────────────────────
# An `if` rather than `[ ... ] && report`: under `set -e` a test that is
# simply FALSE becomes the function's non-zero exit status and kills the
# script, so a clean scan looked exactly like a failing one.
scan_pattern() {   # $1 = human name, $2 = ERE
    local n
    # `--` because a pattern may legitimately begin with a dash, which
    # grep would otherwise read as a flag and abort on.
    n="$(printf '%s\n' "$ADDED" | grep -cE -- "$2" || true)"
    if [ "${n:-0}" -gt 0 ]; then
        report "$1" "$n" "$2"
    fi
}

scan_pattern "Anthropic API key"      'sk-ant-[A-Za-z0-9_-]{24,}'
scan_pattern "OpenAI-style API key"   'sk-[A-Za-z0-9]{32,}'
scan_pattern "GitHub personal token"  'gh[pousr]_[A-Za-z0-9]{30,}'
scan_pattern "GitHub fine-grained PAT" 'github_pat_[A-Za-z0-9_]{30,}'
scan_pattern "AWS access key id"      'AKIA[0-9A-Z]{16}'
scan_pattern "Google API key"         'AIza[0-9A-Za-z_-]{35}'
scan_pattern "Slack token"            'xox[baprs]-[A-Za-z0-9-]{10,}'
scan_pattern "private key block"      '[-]{5}BEGIN [A-Z ]*PRIVATE KEY'

# ── Personal and local-machine identifiers, derived at runtime ───────────
# grep -F: these are literal values, and a name or a path can contain regex
# metacharacters.
scan_literal() {   # $1 = human name, $2 = literal needle
    local n
    [ -z "$2" ] && return 0
    n="$(printf '%s\n' "$ADDED" | grep -cFi -- "$2" || true)"
    if [ "${n:-0}" -gt 0 ]; then
        if [ "$FAILED" -eq 0 ]; then
            echo >&2
            echo "== secret-scan: staged content is not safe to commit ==" >&2
        fi
        FAILED=1
        echo >&2
        echo "  $1 appears in $n added line(s)." >&2
        echo "  Replace it with a placeholder such as [REDACTED-NAME] or Jane Doe." >&2
    fi
}

GIT_NAME="$(git config user.name  || true)"
GIT_MAIL="$(git config user.email || true)"

scan_literal "the committer's name"  "$GIT_NAME"
scan_literal "the committer's email" "$GIT_MAIL"
scan_literal "an absolute home path" "$HOME"
if [ -n "${USER:-}" ]; then
    scan_literal "the local username" "/Users/$USER"
fi

if [ "$FAILED" -ne 0 ]; then
    echo >&2
    echo "  Nothing was committed. Redact the values above and re-run." >&2
    echo "  If a match is a false positive, override deliberately:" >&2
    echo "    SKIP_SECRET_SCAN=1 Scripts/shipit.sh ..." >&2
    echo >&2
    exit 1
fi

echo "secret-scan: clean"
