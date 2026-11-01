@echo off
rem Convenience wrapper so the installer can be run from cmd.exe or Explorer.
rem Any arguments are forwarded to install-release.ps1 (-DryRun, -WaitForGameSeconds -1, ...).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-release.ps1" %*
exit /b %ERRORLEVEL%
