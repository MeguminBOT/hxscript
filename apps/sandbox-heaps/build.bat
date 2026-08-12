@echo off
rem Builds the hxScript Sandbox (HashLink Heaps) on Windows.
rem
rem   build.bat                 build it as bytecode the VM runs
rem   build.bat run             build, then launch it
rem   build.bat bundle          build, then assemble a folder that runs without HashLink installed
rem   build.bat hlc             build it as an ordinary native binary instead
rem   build.bat hlc run         and launch it
rem   build.bat hlc bundle      and assemble a folder from it
rem   build.bat hlc --no-jit    without the loader, which is the build an arm64 target gets
rem   build.bat --debug         debug build
rem   build.bat --clean         wipe the build output first
rem
rem The two shipping modes are the same program. common.hxml is the whole build and the two target
rem files add one line each, so hlc is a decision about how this ships rather than a different
rem application. What differs afterwards is packaging, and bundle is where that is visible.
rem
rem Run setup\windows.bat once first. It installs the haxelibs, including hxscript from git, into a
rem haxelib repository belonging to this folder.
rem
rem Three environment variables, all optional:
rem
rem   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
rem   HLPATH         where HashLink is, if hl is not on your path
rem   HL_SRC         a hashlink source tree, which the HL/C loader is built from

setlocal enabledelayedexpansion
cd /d "%~dp0"

set "MODE=release"
set "CLEAN=0"
set "LAUNCH=0"
set "BUNDLE=0"
set "NATIVE=0"
set "JIT=1"

:args
if "%~1"=="" goto args_done
if /i "%~1"=="run" ( set "LAUNCH=1" & shift & goto args )
if /i "%~1"=="bundle" ( set "BUNDLE=1" & shift & goto args )
if /i "%~1"=="hlc" ( set "NATIVE=1" & shift & goto args )
if /i "%~1"=="--no-jit" ( set "JIT=0" & shift & goto args )
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

rem Needed either way, and for different reasons. Bytecode needs it to run at all; a native binary
rem never runs it but links against the libhl and the .hdll files that live beside it.
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

if "%NATIVE%"=="1" goto build_native

if "%CLEAN%"=="1" if exist export rmdir /s /q export

echo Building (%MODE%) ...
if "%MODE%"=="debug" ( call haxe sandbox.hxml -debug ) else ( call haxe sandbox.hxml )
if errorlevel 1 exit /b 1

if not exist "export\hxscript.hdll" (
	echo.
	echo No hxscript.hdll beside the output, so scripts will be interpreted rather than compiled.
	echo To change that: %LIBPATH%\src\hxscript\hl\hdll.bat --out export
)

rem The templates are read from disk beside the executable rather than embedded, so the folder has
rem to be there for projects\ to be seeded on a first run.
if not exist "export\assets" mkdir "export\assets"
xcopy /e /i /y /q "assets\templates" "export\assets\templates" >nul

echo Built export\sandbox.hl
set "OUTDIR=export"
goto built

:build_native

if "%CLEAN%"=="1" if exist "export\hlc" rmdir /s /q "export\hlc"

echo Building (%MODE%, HL/C) ...
if "%MODE%"=="debug" ( call haxe sandbox-hlc.hxml -debug ) else ( call haxe sandbox-hlc.hxml )
if errorlevel 1 exit /b 1

echo Compiling the native binary ...

rem The library's own tooling rather than a compile line kept here, so this app is a consumer of what
rem hxScript ships exactly as any other host would be. It works out the hashlink sources, the
rem compiler and what to link; HL_SRC and CC override what it decides.
if "%JIT%"=="1" (
	call "%LIBPATH%\src\hxscript\hl\hlc.bat" export\hlc --out export\hlc\Sandbox.exe
) else (
	call "%LIBPATH%\src\hxscript\hl\hlc.bat" export\hlc --out export\hlc\Sandbox.exe --no-jit
)
if errorlevel 1 exit /b 1

if not exist "export\hlc\assets" mkdir "export\hlc\assets"
xcopy /e /i /y /q "assets\templates" "export\hlc\assets\templates" >nul
call :runtime "export\hlc"

echo Built export\hlc\Sandbox.exe
if "%JIT%"=="0" echo   without the loader, so every script will be interpreted
set "OUTDIR=export\hlc"

:built

rem --- bundle ------------------------------------------------------------------------------------

rem Where the two shipping modes stop looking alike.
rem
rem Bytecode means shipping the VM: nothing is compiled or linked here, hl opens hlboot.dat when it
rem is given no argument, so a renamed VM beside a renamed .hl is a double-clickable application. The
rem script compiler is hxscript.hdll beside it and can be left out per release.
rem
rem HL/C means shipping the program: it is already an executable, there is no bytecode file at all,
rem and the script compiler is inside it rather than beside it. libhl and the .hdll files it binds
rem still have to be there, because those are dynamic libraries either way.
rem
rem One caveat belongs to bytecode only: hlboot.dat is opened relative to the WORKING directory
rem rather than to the executable. Explorer sets that to the folder it launched from, so
rem double-clicking works; a shortcut with a different "start in" does not.
if "%BUNDLE%"=="1" (
	if exist bundle rmdir /s /q bundle
	mkdir bundle
	mkdir "bundle\assets"

	if "%NATIVE%"=="1" (
		copy /y "export\hlc\Sandbox.exe" "bundle\Sandbox.exe" >nul
	) else (
		copy /y "%HLPATH%\hl.exe" "bundle\Sandbox.exe" >nul
		copy /y "export\sandbox.hl" "bundle\hlboot.dat" >nul
		if exist "export\hxscript.hdll" copy /y "export\hxscript.hdll" "bundle\" >nul
	)

	xcopy /e /i /y /q "assets\templates" "bundle\assets\templates" >nul
	call :runtime "bundle"

	echo Bundled bundle\ - copy it anywhere and run the executable in it
)

if "%LAUNCH%"=="1" (
	echo Launching ...
	pushd "%OUTDIR%"
	if "%NATIVE%"=="1" ( Sandbox.exe ) else ( "%HLPATH%\hl.exe" sandbox.hl )
	popd
)

exit /b 0

rem --- helpers -----------------------------------------------------------------------------------

rem Copies libhl, the .hdll files this program binds, and the shared libraries they need.
rem
rem What it binds is read rather than remembered. hlc.json is written beside the generated C and
rem names every library the program binds, which is the only place that answer is kept honest by the
rem compiler. A list written out by hand here was wrong for as long as it existed: it carried heaps
rem and openal, which this app does not bind, and omitted ui and uv, which it does, so a bundle made
rem from it was missing two libraries and nobody found out because nobody had run one.
rem
rem std is libhl itself and hxscript is the script compiler, which is a .hdll beside the output on
rem the VM and linked into the binary on HL/C. Neither is a file to copy from the HashLink install.
:runtime
for %%f in (libhl.dll SDL3.dll SDL2.dll OpenAL32.dll) do (
	if exist "%HLPATH%\%%f" copy /y "%HLPATH%\%%f" "%~1\" >nul
)

set "BOUND="
if exist "export\hlc\hlc.json" (
	for /f "delims=" %%l in ('findstr /r /c:"\"libs\"" "export\hlc\hlc.json"') do (
		set "LINE=%%l"
		set "LINE=!LINE:"libs"=!"
		set "LINE=!LINE:[=!"
		set "LINE=!LINE:]=!"
		set "LINE=!LINE::=!"
		set "LINE=!LINE:"=!"
		set "LINE=!LINE:,= !"
		set "BOUND=!LINE!"
	)
)
if not defined BOUND set "BOUND=fmt sdl ui uv"

for %%n in (!BOUND!) do (
	if not "%%n"=="std" if not "%%n"=="hxscript" (
		if exist "%HLPATH%\%%n.hdll" copy /y "%HLPATH%\%%n.hdll" "%~1\" >nul
	)
)
exit /b 0
