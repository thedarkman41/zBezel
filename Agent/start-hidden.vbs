' Launches the Bezel agent with no console window, and keeps it running.
'
' The logon task starts this once per sign-in. It used to launch the agent and
' exit, so an agent that died (a crash, a kill, a failed redeploy) stayed dead
' until the next logon: the proxy answered "connection refused" on 9110 and the
' KVM channel reconnected for ever against a pipe nobody was serving. Waiting on
' the agent and starting it again is the whole fix.
'
' Anything that replaces BezelAgent.exe must stop the BezelAgentService task
' FIRST (Stop-ScheduledTask), or this loop restarts the agent mid-build and
' holds the file open.
Dim shell, exePath
Set shell = CreateObject("WScript.Shell")
exePath = shell.ExpandEnvironmentStrings("%USERPROFILE%") & "\bezel\BezelAgent.exe"
Do
    shell.Run """" & exePath & """ serve", 0, True
    WScript.Sleep 5000
Loop
