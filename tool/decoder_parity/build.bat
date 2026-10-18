@echo off
rem Builds decode64.exe (SoLoud's dr_mp3 + x64 BASS, e.g. lazer) and decode32.exe (x86 BASS, osu!stable).
rem Usage after build (in this folder, after `python gen.py`):
rem   decode64 drmp3 noxing.mp3
rem   decode32 bass "F:\Games\osu!\bass.dll" -1 noxing.mp3        (-1 = leave BASS config alone)
rem   decode64 bass "%LOCALAPPDATA%\osulazer\current\bass.dll" 1 noxing.mp3   (1 = BASS_CONFIG_MP3_OLDGAPS on, as lazer)
cd /d %~dp0
copy /y "%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\flutter_soloud-5.1.6\src\soloud\src\audiosource\wav\dr_mp3.h" . >nul || exit /b 1
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /O2 decode.c /Fe:decode64.exe || exit /b 1
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars32.bat" >nul
cl /nologo /O2 decode.c /Fe:decode32.exe || exit /b 1
echo built
