@echo off
rem Starts NV-AI without a console window unless it is already running, and returns at once.
rem NV-AI is ready as soon as GET /api/version answers.
rem The PhotoCraft bridge calls this file via HKCU\Software\NV-AI\InstallDir.
rem /D: fixed working folder - "python -m" would otherwise load modules from the caller's folder.
start "" /D "%~dp0server" "%~dp0server\.venv\Scripts\pythonw.exe" -m nvai.launcher %*
