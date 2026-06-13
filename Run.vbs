Set objFSO = CreateObject("Scripting.FileSystemObject")
strPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
Set objShell = CreateObject("WScript.Shell")

' FormatBackupAnalyzer.ps1 dosyasını arka planda çalıştır (penceresiz/sessiz)
analyzerCmd = "powershell -NoProfile -STA -ExecutionPolicy Bypass -File """ & strPath & "\FormatBackupAnalyzer.ps1"""
objShell.Run analyzerCmd, 0, False
