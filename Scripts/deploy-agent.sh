#!/bin/zsh
# Deploy BezelAgent to a Windows host that can reach the monitor over DDC/CI,
# and register it to start in that machine's interactive desktop session.
#
#   ./Scripts/deploy-agent.sh [ssh-host]     (default: rigel)
#
# Requires passwordless SSH to the host and a logged-in console session there.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-rigel}"
CSC='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

[[ -f "$REPO/Agent/BezelAgent.cs" ]] || { echo "not the Bezel repo: $REPO" >&2; exit 1; }

echo "==> copying agent sources to $HOST"
ssh "$HOST" 'New-Item -ItemType Directory -Force -Path "$HOME\bezel" | Out-Null'
scp -q "$REPO/Agent/BezelAgent.cs" \
       "$REPO/Agent/start-hidden.vbs" \
       "$REPO/Agent/install-service.ps1" \
       "$HOST:bezel/"

echo "==> compiling on $HOST"
# The running service holds the executable open, so stop it before rebuilding.
ssh "$HOST" "Get-Process BezelAgent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
& '$CSC' /nologo /optimize+ /warn:4 /warnaserror /target:exe /out:\"\$HOME\\bezel\\BezelAgent.exe\" \"\$HOME\\bezel\\BezelAgent.cs\"
if (-not (Test-Path \"\$HOME\\bezel\\BezelAgent.exe\")) { throw 'compile failed' }"

echo "==> registering the logon service"
ssh "$HOST" 'powershell -ExecutionPolicy Bypass -File "$HOME\bezel\install-service.ps1"'

echo "==> verifying"
ssh "$HOST" '& "$HOME\bezel\BezelAgent.exe" client list'

cat <<NOTE

Done. Bezel on the Mac will use this host automatically when its own DDC/CI
path is blocked. Set the hostname on Bezel's Link tab if it is not "$HOST".

The agent MUST run in the interactive desktop session: the Windows Monitor
Configuration API enumerates no monitors from an SSH session (session 0). That
is why it is a logon scheduled task rather than a Windows service.
NOTE
