# Runs BezelAgent inside the interactive desktop session and returns its JSON.
#
# Necessary because the Monitor Configuration API needs a real window station:
# an SSH session lands in session 0 and sees no monitors at all. A scheduled task
# with an Interactive principal runs in the console session, where it does.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$AgentArgs)

$ErrorActionPreference = "Stop"
$dir = Join-Path $env:USERPROFILE "bezel"
$out = Join-Path $dir "agent-out.json"
$bat = Join-Path $dir "agent-run.bat"
$exe = Join-Path $dir "BezelAgent.exe"

if (Test-Path $out) { Remove-Item $out -Force }

$quoted = ($AgentArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
$lines = @('@echo off', ('"{0}" {1} > "{2}" 2>&1' -f $exe, $quoted, $out))
Set-Content -Path $bat -Value $lines -Encoding ASCII

$me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute $bat
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName "BezelAgentRun" -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "BezelAgentRun"

# Redirection creates the output file immediately, so the file existing proves
# nothing. Wait for the task itself to leave the Running state.
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 200
    $state = (Get-ScheduledTask -TaskName "BezelAgentRun").State
    if ($state -ne "Running") { break }
}
Start-Sleep -Milliseconds 150

if (Test-Path $out) {
    $text = (Get-Content $out -Raw)
    if ([string]::IsNullOrWhiteSpace($text)) { '{"ok":false,"error":"agent produced empty output"}' }
    else { $text.Trim() }
} else {
    '{"ok":false,"error":"agent produced no output"}'
}
