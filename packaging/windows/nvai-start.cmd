@echo off
rem Starts NV-AI without a console window unless it is already running, and returns at once.
rem NV-AI is ready as soon as GET /api/version answers.
rem The PhotoCraft bridge calls this file via HKCU\Software\NV-AI\InstallDir.
start "" "%~dp0server\.venv\Scripts\pythonw.exe" -m nvai.launcher %*
