@echo off
rem Builds the hxScript Sandbox (HashLink Heaps) on Windows.
rem
rem   build.bat                 build it
rem   build.bat run             build, then launch it
rem   build.bat bundle          build, then assemble a folder that runs on a machine without HashLink
rem   build.bat --with-tests    including the conformance projects, which test/all.sh drives
rem   build.bat --no-jit        without the loader, which is the build an arm64 target gets
rem   build.bat --debug         debug build
rem   build.bat --clean         wipe the build output first
rem
rem This ships as a native binary, not as bytecode. Haxe writes C, the C compiles to an executable,
rem and there is no VM process and no .hl file. That is the half worth demonstrating: on the VM a
rem script compiler can be dropped in beside the program as a .hdll and this app would prove nothing
rem the VM does not already do, while here it has to be compiled into the executable.
rem
rem Run setup\windows.bat once first. It installs the haxelibs into a haxelib repository belonging to
rem this folder.
rem
rem Three environment variables, all optional:
rem
rem   HXSCRIPT_PATH  where hxscript is checked out, if it is not this repository
rem   HLPATH         where HashLink is, if hl is not on your path
rem   HL_SRC         a hashlink source tree to build the loader from, instead of the carried one

setlocal enabledelayedexpansion
cd /d "%~dp0"

set "MODE=release"
set "CLEAN=0"
set "LAUNCH=0"
set "BUNDLE=0"
set "JIT=1"
set "TESTS=0"

:args
if "%~1"=="" goto args_done
if /i "%~1"=="run" ( set "LAUNCH=1" & shift & goto args )
if /i "%~1"=="bundle" ( set "BUNDLE=1" & shift & goto args )
if /i "%~1"=="--with-tests" ( set "TESTS=1" & shift & goto args )
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

rem --- HashLink ----------------------------------------------------------------------------------

rem Never run, and still needed. The binary links against libhl and against the .hdll files this
rem program binds, and it is compiled against that installation's hl.h.
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

if "%CLEAN%"=="1" if exist "export\hlc" rmdir /s /q "export\hlc"

echo Building (%MODE%) ...
if "%MODE%"=="debug" ( call haxe sandbox.hxml -debug ) else ( call haxe sandbox.hxml )
if errorlevel 1 exit /b 1

echo Compiling the native binary ...

rem The library's own tooling rather than a compile line kept here, so this app is a consumer of what
rem hxScript ships exactly as any other host would be. It works out the loader sources, the compiler
rem and what to link; HL_SRC and CC override what it decides.
if "%JIT%"=="1" (
	call sh "%LIBPATH%\src\hxscript\hl\native\build.sh" --hlc export/hlc --out export/hlc/Sandbox.exe
) else (
	call sh "%LIBPATH%\src\hxscript\hl\native\build.sh" --hlc export/hlc --out export/hlc/Sandbox.exe --no-jit
)
if errorlevel 1 exit /b 1

rem The templates are read from disk beside the executable rather than embedded, so the folder has
rem to be there for projects\ to be seeded on a first run.
if not exist "export\hlc\assets" mkdir "export\hlc\assets"
if exist "export\hlc\assets\conformance" rmdir /s /q "export\hlc\assets\conformance"
xcopy /e /i /y /q "assets\templates" "export\hlc\assets\templates" >nul
xcopy /e /i /y /q "assets\res" "export\hlc\assets\res" >nul

rem The conformance projects are fixtures rather than examples, so they are copied only when asked
rem for. Without this every build shows three test harnesses in its example list.
if "%TESTS%"=="1" xcopy /e /i /y /q "test\projects" "export\hlc\assets\conformance" >nul
call :runtime "export\hlc"

echo Built export\hlc\Sandbox.exe
if "%JIT%"=="0" echo   without the loader, so every script will be interpreted
set "OUTDIR=export\hlc"

rem --- bundle ------------------------------------------------------------------------------------

rem Shipping a native binary is shipping the program. There is no bytecode file and no VM to carry,
rem and the script compiler is inside the executable rather than beside it. libhl and the .hdll files
rem it binds still have to be there, because those are dynamic libraries either way.
if "%BUNDLE%"=="1" (
	if exist bundle rmdir /s /q bundle
	mkdir bundle
	mkdir "bundle\assets"

	copy /y "export\hlc\Sandbox.exe" "bundle\Sandbox.exe" >nul

	xcopy /e /i /y /q "assets\templates" "bundle\assets\templates" >nul
	xcopy /e /i /y /q "assets\res" "bundle\assets\res" >nul
	call :runtime "bundle"

	echo Bundled bundle\ - copy it anywhere and run the executable in it
)

if "%LAUNCH%"=="1" (
	echo Launching ...
	pushd "%OUTDIR%"
	Sandbox.exe
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
rem std is libhl itself and hxscript is the script compiler, which is compiled into the binary.
rem Neither is a file to copy from the HashLink install.
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
