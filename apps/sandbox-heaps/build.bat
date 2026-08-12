@echo off
rem Builds the hxScript Sandbox (HashLink Heaps) on Windows.
rem
rem   build.bat                 build it
rem   build.bat run             build, then launch it
rem   build.bat --debug         debug build
rem   build.bat --clean         wipe the build output first
rem
rem Run setup\windows.bat once first. It installs the haxelibs, including hxscript from git, into a
rem haxelib repository belonging to this folder.
rem
rem Two environment variables, both optional:
rem
rem   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
rem   HLPATH         where HashLink is, if hl is not on your path

setlocal enabledelayedexpansion
cd /d "%~dp0"

set "MODE=release"
set "CLEAN=0"
set "LAUNCH=0"

:args
if "%~1"=="" goto args_done
if /i "%~1"=="run" ( set "LAUNCH=1" & shift & goto args )
if /i "%~1"=="--debug" ( set "MODE=debug" & shift & goto args )
if /i "%~1"=="--clean" ( set "CLEAN=1" & shift & goto args )
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
echo build.bat: unknown argument '%~1' 1>&2
echo try: build.bat --help 1>&2
exit /b 2

:usage
for /f "tokens=1,* delims=:" %%a in ('findstr /n "^rem" "%~f0"') do @echo(%%b
exit /b 0

:args_done

rem --- the toolchain -----------------------------------------------------------------------------

where haxe >nul 2>&1 || ( echo build.bat: no haxe on your path. https://haxe.org/download 1>&2 & exit /b 1 )

if not exist ".haxelib" (
	echo build.bat: no local haxelib repository here. Run setup\windows.bat once first. 1>&2
	exit /b 1
)

for %%l in (heaps hlsdl format hxscript) do (
	call haxelib path %%l >nul 2>&1 || ( echo build.bat: %%l is not installed. Run setup\windows.bat once first. 1>&2 & exit /b 1 )
)

rem A checkout of hxscript at this repository wins over whatever setup installed, so edits to the
rem library are what gets built.
set "LIBPATH=%HXSCRIPT_PATH%"
if not defined LIBPATH set "LIBPATH=%~dp0..\.."
if exist "%LIBPATH%\haxelib.json" call haxelib dev hxscript "%LIBPATH%" >nul 2>&1

rem --- the VM ------------------------------------------------------------------------------------

if not defined HLPATH (
	for /f "delims=" %%p in ('where hl.exe 2^>nul') do (
		if not defined HLPATH (
			set "HLPATH=%%~dpp"
			set "HLPATH=!HLPATH:~0,-1!"
		)
	)
)

if not defined HLPATH (
	echo build.bat: no HashLink found. Install it, or set HLPATH to the directory holding hl.exe 1>&2
	echo            https://hashlink.haxe.org 1>&2
	exit /b 1
)

rem --- build -------------------------------------------------------------------------------------

if "%CLEAN%"=="1" if exist export rmdir /s /q export

echo Building (%MODE%) ...
if "%MODE%"=="debug" ( call haxe sandbox.hxml -debug ) else ( call haxe sandbox.hxml )
if errorlevel 1 exit /b 1

if not exist "export\hxscript.hdll" (
	echo.
	echo No hxscript.hdll beside the output, so scripts will be interpreted rather than compiled.
	echo To change that: ..\..\src\hxscript\hl\hdll.bat --out export
)

rem The templates are read from disk beside the executable rather than embedded, so the folder has
rem to be there for projects\ to be seeded on a first run.
if not exist "export\assets" mkdir "export\assets"
xcopy /e /i /y /q "assets\templates" "export\assets\templates" >nul

echo Built export\sandbox.hl

if "%LAUNCH%"=="1" (
	echo Launching ...
	pushd export
	"%HLPATH%\hl.exe" sandbox.hl
	popd
)

exit /b 0
