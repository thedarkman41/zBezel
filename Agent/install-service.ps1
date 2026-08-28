# Registers the Bezel agent as a logon task in the interactive desktop session.
#
# The Monitor Configuration API needs a real window station. A task with an
# Interactive principal runs in the console session where monitors are visible;
# an SSH session (session 0) never is.
$ErrorActionPreference = "Stop"
$dir  = Join-Path $env:USERPROFILE "bezel"
$vbs  = Join-Path $dir "start-hidden.vbs"
$name = "BezelAgentService"

$me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"{0}"' -f $vbs)
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# Stop any previous instance so the port is free, then start fresh.
Get-Process BezelAgent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400
Start-ScheduledTask -TaskName $name
Start-Sleep -Seconds 2

$proc = Get-Process BezelAgent -ErrorAction SilentlyContinue
if ($proc) { "SERVICE RUNNING pid=$($proc.Id) session=$($proc.SessionId)" }
else { "SERVICE NOT RUNNING" }
