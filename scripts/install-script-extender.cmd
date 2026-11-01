@echo off
rem Convenience wrapper so the Script Extender installer can be run from
rem cmd.exe or Explorer. Any arguments are forwarded to
rem install-script-extender.ps1 (-FromPath, -Tag, -DryRun, ...).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-script-extender.ps1" %*
exit /b %ERRORLEVEL%
