@echo off
setlocal EnableDelayedExpansion
rem Builds the hxScript Sandbox (Lime HXCPP) on Windows.
rem
rem   build.bat                 release build
rem   build.bat run             build, then launch it
rem   build.bat --debug         debug build
rem   build.bat --clean         wipe the build output first
rem   build.bat linux           build for a named target: windows ^| linux ^| mac
rem
rem Run setup\windows.bat once first. It installs the haxelibs, including hxscript and SmidrUI from
rem git, into a haxelib repository belonging to this folder.
rem
rem Two environment variables, both optional:
rem
rem   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
rem   SMIDR_PATH     where SmidrUI is checked out, if it is not a sibling of this repository
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
	echo lime is not installed. Run the setup script first:  setup\windows.bat
	exit /b 1
)

rem ---- the libraries ---------------------------------------------------------
rem
rem setup\windows.bat installs every one of these, including hxscript and SmidrUI from git, into a
rem haxelib repository belonging to this folder. It is the thing to run on a machine that has not
rem built this before, and this script does not do its job: what happens here is only the checkout
rem override.
rem
rem If hxscript or SmidrUI is checked out where this can find it, haxelib is pointed at that
rem checkout, so somebody working on either library builds against their edits rather than against
rem what setup installed. HXSCRIPT_PATH and SMIDR_PATH name a checkout that is somewhere else;
rem neither is needed when the library is a sibling of this repository.

for %%p in ("%REPO%") do set "REPO=%%~fp"

set "HXSCRIPT=%HXSCRIPT_PATH%"

if "!HXSCRIPT!"=="" (
	for %%g in ("%REPO%" "%REPO%\..\hxscript" "%REPO%\..\hxScript") do (
		if exist "%%~fg\src\hxscript" if "!HXSCRIPT!"=="" set "HXSCRIPT=%%~fg"
	)
)

if not "!HXSCRIPT!"=="" (
	echo hxscript    !HXSCRIPT!
	call haxelib dev hxscript "!HXSCRIPT!" >nul
) else (
	echo hxscript    ^(haxelib^)
)

set "SMIDR=%SMIDR_PATH%"

if "!SMIDR!"=="" (
	for %%g in ("%REPO%\..\SmidrUI" "%REPO%\..\smidr") do (
		if exist "%%~fg\src\smidr" if "!SMIDR!"=="" set "SMIDR=%%~fg"
	)
)

if not "!SMIDR!"=="" (
	echo smidr       !SMIDR!
	call haxelib dev smidr "!SMIDR!" >nul
) else (
	echo smidr       ^(haxelib^)
)

rem ---- the rest of the haxelibs ----------------------------------------------

set "MISSING="

for %%l in (lime openfl flixel flixel-addons flixel-ui hxscript smidr) do (
	call haxelib path %%l >nul 2>&1
	if errorlevel 1 set "MISSING=!MISSING! %%l"
)

if not "!MISSING!"=="" (
	echo.
	echo Missing haxelibs:!MISSING!
	echo.
	echo Run the setup script, which installs all of them into a repository of this folder's own:
	echo.
	echo   setup\windows.bat
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
echo HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
echo SMIDR_PATH     where SmidrUI is checked out, if it is not a sibling of this repository
exit /b 0
