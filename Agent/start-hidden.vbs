' Launches the Bezel agent with no console window.
Dim shell, exePath
Set shell = CreateObject("WScript.Shell")
exePath = shell.ExpandEnvironmentStrings("%USERPROFILE%") & "\bezel\BezelAgent.exe"
shell.Run """" & exePath & """ serve", 0, False
