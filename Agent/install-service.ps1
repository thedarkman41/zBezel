# Registers the Bezel agent as a logon task in the interactive desktop session.
#
# The Monitor Configuration API needs a real window station. A task with an
# Interactive principal runs in the console session where monitors are visible;
# an SSH session (session 0) never is.
#
# RunLevel is Highest, and that is a deliberate change from Limited. It is
# required by the KVM receiver, not by the DDC commands.
#
# UIPI silently discards synthetic input from a process at a lower integrity
# level than the window receiving it. The symptom is not an error: SendInput
# returns success, having queued events that are then dropped, and SetCursorPos
# simply returns false. Measured on this machine at Limited, every injected
# event was accepted and none of them moved the pointer; at Highest the same
# events land exactly. Running Limited would make the KVM work or not work
# depending on which window happened to have focus, which is worse than not
# working at all.
#
# The cost is real and worth stating plainly. The agent is now High integrity,
# so anything that can reach its input pipe can synthesise input into elevated
# windows. The pipe's DACL admits only the account already running the console
# session, and that account is an administrator who can elevate on its own, so
# no boundary Microsoft treats as a security boundary is crossed — UAC and UIPI
# are explicitly not one. It does mean a medium-integrity process running as
# that same user could reach it, which is tracked as a known gap rather than
# claimed to be handled.
$ErrorActionPreference = "Stop"
$dir  = Join-Path $env:USERPROFILE "bezel"
$vbs  = Join-Path $dir "start-hidden.vbs"
$name = "BezelAgentService"

$me        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action    = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ('"{0}"' -f $vbs)
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $me
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
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

# ---------------------------------------------------------------------------
# Second task: the console reclaim, as SYSTEM.
#
# This is what makes a keyboardless machine recoverable. RDP in from elsewhere,
# authenticate, disconnect — the session survives as Disconnected — then trigger
# this and it lands on the physical console, where the Monitor Configuration API
# can see the real panel. From an RDP session it cannot: it enumerates the
# virtual RDP display instead.
#
# It is a SEPARATE task, and SYSTEM, because moving a session needs
# SeTcbPrivilege. An elevated administrator token does not carry it — measured,
# not assumed: whoami /priv in an elevated SSH session lists 24 privileges and
# SeTcbPrivilege is not among them. The logon task above is Interactive and
# could never do this.
#
# There is no trigger. It is only ever started on demand:
#     schtasks /run /tn BezelReclaimConsole
# which is reachable over plain SSH, and deliberately so — when nobody is logged
# in, the agent's own relay is not running either, so SSH is the only path left.
$reclaimName = "BezelReclaimConsole"
$exe         = Join-Path $dir "BezelAgent.exe"

$reclaimAction = New-ScheduledTaskAction -Execute $exe -Argument "reclaim" -WorkingDirectory $dir
$reclaimPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
                        -LogonType ServiceAccount -RunLevel Highest
$reclaimSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -StartWhenAvailable `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $reclaimName -Action $reclaimAction `
    -Principal $reclaimPrincipal -Settings $reclaimSettings `
    -Description "Moves a disconnected RDP session onto the console. Needs SeTcbPrivilege, hence SYSTEM." `
    -Force | Out-Null

$reclaimTask = Get-ScheduledTask -TaskName $reclaimName -ErrorAction SilentlyContinue
if ($reclaimTask) { "RECLAIM TASK REGISTERED" } else { "RECLAIM TASK MISSING" }
