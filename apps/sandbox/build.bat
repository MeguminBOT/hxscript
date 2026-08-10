@echo off
setlocal EnableDelayedExpansion
rem Builds the hxScript sandbox on Windows.
rem
rem   build.bat                 release build
rem   build.bat run             build, then launch it
rem   build.bat --debug         debug build
rem   build.bat --clean         wipe the build output first
rem   build.bat linux           build for a named target: windows ^| linux ^| mac
rem
rem One environment variable, optional:
rem
rem   SMIDR_PATH   where SmidrUI is checked out, if it is not a sibling of this repository
rem
rem The point of this over calling lime directly is the checks. A missing haxelib fails inside lime
rem with a stack trace naming a file in lime rather than the library you have not installed, and the
rem `lime` command itself only exists after `haxelib run lime setup`. Everything below is about
rem turning those into one sentence each.

set "HERE=%~dp0"
set "REPO=%HERE%..\.."
set "TARGET="
set "MODE=release"
set "CLEANFIRST=no"
set "LAUNCH=no"
set "FLAGS="

:args
if "%~1"=="" goto argsdone
if /I "%~1"=="windows" set "TARGET=windows" & goto argsnext
if /I "%~1"=="linux"   set "TARGET=linux"   & goto argsnext
if /I "%~1"=="mac"     set "TARGET=mac"     & goto argsnext
if /I "%~1"=="html5"   set "TARGET=html5"   & goto argsnext
if /I "%~1"=="hl"      set "TARGET=hl"      & goto argsnext
if /I "%~1"=="run"     set "LAUNCH=yes"     & goto argsnext
if /I "%~1"=="--debug" set "MODE=debug"     & goto argsnext
if /I "%~1"=="-debug"  set "MODE=debug"     & goto argsnext
if /I "%~1"=="--clean" set "CLEANFIRST=yes" & goto argsnext
if /I "%~1"=="-clean"  set "CLEANFIRST=yes" & goto argsnext
if /I "%~1"=="--help"  goto help
if /I "%~1"=="-h"      goto help
echo build.bat: unknown argument '%~1'
echo try: build.bat --help
exit /b 2
:argsnext
shift
goto args
:argsdone

if "%TARGET%"=="" set "TARGET=windows"
if "%MODE%"=="debug" set "FLAGS=-debug"

rem ---- the toolchain ---------------------------------------------------------

where haxe >nul 2>&1
if errorlevel 1 (
	echo haxe is not on PATH. Install Haxe 4.3 or newer: https://haxe.org/download/
	exit /b 1
)

for /f "delims=" %%v in ('haxe --version 2^>^&1') do (
	echo haxe        %%v
	goto haxedone
)
:haxedone

call haxelib path lime >nul 2>&1
if errorlevel 1 (
	echo lime is not installed. Run:  haxelib install lime
	exit /b 1
)

rem ---- the dev haxelibs ------------------------------------------------------
rem
rem hxscript is this repository, and SmidrUI is not on haxelib at all, so both have to be pointed at
rem a checkout. Doing it here rather than documenting it means the build works on a fresh clone.

for %%p in ("%REPO%") do set "REPO=%%~fp"
echo hxscript    %REPO%
call haxelib dev hxscript "%REPO%" >nul

set "SMIDR=%SMIDR_PATH%"

if "%SMIDR%"=="" (
	for %%g in ("%REPO%\..\SmidrUI" "%REPO%\..\smidr") do (
		if exist "%%~fg\src\smidr" set "SMIDR=%%~fg"
	)
)

if "%SMIDR%"=="" (
	call haxelib path smidr >nul 2>&1
	if errorlevel 1 (
		echo SmidrUI not found. Clone it and point this at it:
		echo   git clone https://github.com/MeguminBOT/SmidrUI
		echo   set SMIDR_PATH=C:\path\to\SmidrUI ^&^& build.bat
		exit /b 1
	)
	echo smidr       ^(from haxelib^)
) else (
	echo smidr       !SMIDR!
	call haxelib dev smidr "!SMIDR!" >nul
)

rem ---- the rest of the haxelibs ----------------------------------------------

set "MISSING="

for %%l in (openfl flixel flixel-addons flixel-ui) do (
	call haxelib path %%l >nul 2>&1
	if errorlevel 1 set "MISSING=!MISSING! %%l"
)

if not "!MISSING!"=="" (
	echo.
	echo Missing haxelibs:!MISSING!
	echo.
	echo Install them with:
	for %%l in (!MISSING!) do echo   haxelib install %%l
	exit /b 1
)

rem ---- build -----------------------------------------------------------------

pushd "%HERE%"

if "%CLEANFIRST%"=="yes" (
	echo cleaning    export\
	if exist export rmdir /s /q export
)

echo building    %TARGET% ^(%MODE%^)
call haxelib run lime build Project.xml %TARGET% %FLAGS%
if errorlevel 1 (
	popd
	exit /b 1
)

rem ---- the projects folder ----------------------------------------------------
rem
rem The app writes this itself on first run, from the templates it carries as assets. Creating it
rem here as well means the thing that comes out of the build is already a folder somebody can drop a
rem project into, without having had to run it once first.

set "OUT=export\%TARGET%\bin"

if exist "%OUT%" (
	if not exist "%OUT%\projects" mkdir "%OUT%\projects"
	echo projects    %OUT%\projects
)

echo.
echo built       %TARGET% ^(%MODE%^)

if "%LAUNCH%"=="yes" (
	echo running     ...
	call haxelib run lime run Project.xml %TARGET% %FLAGS%
) else (
	echo run it      build.bat %TARGET% run
)

popd
exit /b 0

:help
echo build.bat                 release build
echo build.bat run             build, then launch it
echo build.bat --debug         debug build
echo build.bat --clean         wipe the build output first
echo build.bat linux           build for a named target: windows ^| linux ^| mac
echo.
echo SMIDR_PATH   where SmidrUI is checked out, if it is not a sibling of this repository
exit /b 0
