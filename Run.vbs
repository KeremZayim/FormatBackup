Set objFSO = CreateObject("Scripting.FileSystemObject")
strPath = objFSO.GetParentFolderName(WScript.ScriptFullName)
Set objShell = CreateObject("WScript.Shell")

' Türkçe karakterlerin bozulmasını önlemek için FormatBackupAnalyzer.ps1 dosyasının UTF-8 BOM kodlamasını doğrula
bomCmd = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""$f = '" & strPath & "\FormatBackupAnalyzer.ps1'; if (Test-Path $f) { $b = [System.IO.File]::ReadAllBytes($f); if ($b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $bom = [byte[]](0xEF, 0xBB, 0xBF); $nb = New-Object byte[] ($bom.Length + $b.Length); [Array]::Copy($bom, 0, $nb, 0, $bom.Length); [Array]::Copy($b, 0, $nb, $bom.Length, $b.Length); [System.IO.File]::WriteAllBytes($f, $nb) } }"""
objShell.Run bomCmd, 0, True

' FormatBackupAnalyzer.ps1 dosyasını arka planda çalıştır (penceresiz/sessiz)
analyzerCmd = "powershell -NoProfile -STA -ExecutionPolicy Bypass -File """ & strPath & "\FormatBackupAnalyzer.ps1"""
objShell.Run analyzerCmd, 0, False
