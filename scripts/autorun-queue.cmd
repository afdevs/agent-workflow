@echo off
REM autorun-queue.cmd — Windows wrapper: runs the bash runner through Git Bash.
REM Git Bash is already required by Claude Code on Windows, so it's present.
REM Usage identique, variables via set :
REM   set QUEUE_MODE=local
REM   set BUDGET_TOTAL=15.00
REM   autorun-queue.cmd

setlocal
where bash >nul 2>nul
if errorlevel 1 (
  echo ERREUR: Git Bash introuvable. Installer Git for Windows ^(requis par Claude Code^).
  exit /b 1
)
bash "%~dp0autorun-queue.sh" %*
endlocal
