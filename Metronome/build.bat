@echo off
setlocal
cd /d "%~dp0"
call "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\VsDevCmd.bat" -arch=x86 >nul
if errorlevel 1 exit /b 1
if not exist build mkdir build
if not exist build\obj mkdir build\obj

set IMGUI=third_party\imgui
cl /nologo /LD /MT /O2 /EHsc /DNDEBUG /Fo"build\obj\\" ^
  /I"%IMGUI%" /I"%IMGUI%\backends" ^
  src\metronome.cpp ^
  "%IMGUI%\imgui.cpp" "%IMGUI%\imgui_draw.cpp" "%IMGUI%\imgui_tables.cpp" ^
  "%IMGUI%\imgui_widgets.cpp" ^
  "%IMGUI%\backends\imgui_impl_win32.cpp" ^
  "%IMGUI%\backends\imgui_impl_dx9.cpp" ^
  /Fe:build\Metronome.dll user32.lib winmm.lib
if errorlevel 1 exit /b 1

cl /nologo /MT /O2 /EHsc /DNDEBUG /Fo"build\obj\\" ^
  src\launcher.cpp src\video_patch.cpp ^
  /Fe:build\MetronomeLauncher.exe user32.lib
if errorlevel 1 exit /b 1

echo.
echo built build\Metronome.dll and build\MetronomeLauncher.exe

