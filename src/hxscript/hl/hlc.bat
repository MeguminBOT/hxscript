@echo off
rem Puts hxScript's runtime compiler into an HL/C program.
rem
rem   hlc.bat --flags              print what to add to a native build you already have
rem   hlc.bat out                  build the C in out\ into an executable
rem   hlc.bat out --out game.exe   name the executable
rem   hlc.bat out --no-jit         leave the loader out, so scripts are interpreted
rem
rem HL/C is the other way to ship HashLink: `haxe -hl out.c` writes C that compiles to an ordinary
rem native binary with no VM process and no bytecode file. The extension is compiled in rather than
rem loaded, and the header Haxe generates for its natives declares exactly the symbols hxscript.c
rem already defines, so the same file serves both ways of shipping.
rem
rem What does not carry over is the `?` that makes the extension optional on HL/JIT. A dlopened
rem library can be absent and leave its natives as stubs; a linked one either resolves or the link
rem fails. An HL/C host therefore decides at build time whether it can compile scripts.
rem
rem Nothing here needs Haxe. `haxelib run hxscript hlc` does the same work, minus the fetching,
rem which is why this exists separately.

setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "HERE=%HERE:~0,-1%"
set "CDIR="
set "EXE="
set "HL=%HLPATH%"
set "SRC=%HL_SRC%"
set "YES=0"
set "JIT=1"
set "FLAGSONLY=0"
set "REPO=https://github.com/HaxeFoundation/hashlink"

:args
if "%~1"=="" goto args_done
if /i "%~1"=="--flags" ( set "FLAGSONLY=1" & shift & goto args )
if /i "%~1"=="--no-jit" ( set "JIT=0" & shift & goto args )
if /i "%~1"=="--out" ( set "EXE=%~2" & shift & shift & goto args )
if /i "%~1"=="--hl" ( set "HL=%~2" & shift & shift & goto args )
if /i "%~1"=="--src" ( set "SRC=%~2" & shift & shift & goto args )
if /i "%~1"=="--yes" ( set "YES=1" & shift & goto args )
if /i "%~1"=="-y" ( set "YES=1" & shift & goto args )
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
if not defined CDIR ( set "CDIR=%~1" & shift & goto args )
echo unknown argument: %~1 1>&2
exit /b 1

:usage
for /f "tokens=1,* delims=:" %%a in ('findstr /n "^rem" "%~f0"') do @echo(%%b
exit /b 0

:args_done

rem --- where libhl is ----------------------------------------------------------------------------

if defined HL call :holds "%HL%" || ( echo no HashLink runtime in %HL% 1>&2 & exit /b 1 )

if not defined HL (
	for /f "delims=" %%p in ('where hl.exe 2^>nul') do (
		if not defined HL (
			set "CAND=%%~dpp"
			set "CAND=!CAND:~0,-1!"
			call :holds "!CAND!" && set "HL=!CAND!"
		)
	)
)

if not defined HL (
	for %%g in ("C:\HaxeToolkit\hl" "C:\hashlink" "C:\Program Files\hashlink") do (
		if not defined HL call :holds "%%~g" && set "HL=%%~g"
	)
)

if not defined HL (
	echo no HashLink was found. Install it, or pass --hl ^<directory holding libhl^> 1>&2
	exit /b 1
)

rem A HashLink install ships include\hl.h, which carries the version. That is the thing to compare a
rem source tree against, and it needs no VM binary, which an HL/C build otherwise has no use for.
set "VERSION="
call :stamped "%HL%\include\hl.h"
if defined STAMPED set "VERSION=%STAMPED%"

if not defined VERSION (
	set "HLEXE=%HL%\hl.exe"
	if exist "!HLEXE!" (
		for /f "delims=" %%v in ('"!HLEXE!" --version 2^>nul') do if not defined VERSION set "VERSION=%%v"
	)
)

if "%FLAGSONLY%"=="0" echo HashLink %VERSION% at %HL%

rem --- the sources -------------------------------------------------------------------------------

rem Only needed for the loader. Without it this compiles one small file against hl.h, which the
rem binary distributions do ship, so an architecture that cannot jit needs no source tree at all.
if "%JIT%"=="0" goto no_loader

if defined SRC call :istree "%SRC%" || ( echo no hashlink sources in %SRC% 1>&2 & exit /b 1 )

if not defined SRC (
	for %%n in ("%HL%\src" "%HL%\.." "%HL%\..\src" "%HL%\..\.." "hashlink-%VERSION%") do (
		if not defined SRC call :istree "%%~fn" && set "SRC=%%~fn"
	)
)

if not defined SRC call :fetch
if not defined SRC exit /b 1

rem The struct layouts in hl.h are shared with the libhl this links against, so a mismatched pair
rem compiles and links cleanly and then reads fields from the wrong offsets.
call :stamped "%SRC%\src\hl.h"
if defined STAMPED if defined VERSION if not "%STAMPED%"=="%VERSION%" (
	echo the sources in %SRC% are hashlink %STAMPED% and %HL% is %VERSION%. Pass --src for a matching tree. 1>&2
	exit /b 1
)

if "%FLAGSONLY%"=="0" echo sources at %SRC%

set "INCLUDES=-I"%SRC%\src" -I"%HERE%""
set "CARRIED="%HERE%\hxscript.c" "%SRC%\src\code.c" "%SRC%\src\module.c" "%SRC%\src\jit.c""
goto have_recipe

:no_loader
if defined SRC if exist "%SRC%\src\hl.h" (
	set "INCLUDES=-DHXS_NO_JIT -I"%SRC%\src" -I"%HERE%""
	goto no_loader_done
)
if exist "%HL%\include\hl.h" (
	set "INCLUDES=-DHXS_NO_JIT -I"%HL%\include" -I"%HERE%""
	goto no_loader_done
)
echo no hl.h was found. Pass --src ^<a hashlink source tree^>, or use an install that ships include\hl.h 1>&2
exit /b 1

:no_loader_done
set "CARRIED="%HERE%\hxscript.c""

:have_recipe

rem --- print and stop ----------------------------------------------------------------------------

if "%FLAGSONLY%"=="1" (
	echo !INCLUDES! !CARRIED!
	exit /b 0
)

if not defined CDIR (
	echo name the directory Haxe generated the HL/C into, or pass --flags 1>&2
	exit /b 1
)

if not exist "%CDIR%\hlc.json" (
	echo there is no hlc.json in %CDIR%, so Haxe did not generate HL/C there 1>&2
	exit /b 1
)

rem --- the compiler ------------------------------------------------------------------------------

if defined CC where "%CC%" >nul 2>&1 || set "CC="

if not defined CC (
	for %%c in (x86_64-w64-mingw32-gcc.exe gcc.exe clang.exe) do (
		if not defined CC where %%c >nul 2>&1 && set "CC=%%~nc"
	)
)

if not defined CC (
	echo no C compiler was found. Install mingw-w64, or set CC 1>&2
	exit /b 1
)

echo compiler %CC%

rem --- what Haxe wrote ---------------------------------------------------------------------------

rem hlc.json names every file Haxe generated and every library the program binds, so it is read
rem rather than the same thing being said twice.
rem
rem Only the first is compiled, and that is not a shortcut. Haxe writes a file per type and then a
rem main file that #includes every one of them, unless HL_MAKE says it is being built the other way,
rem so compiling the list as well would define everything twice and fail the link on a few hundred
rem duplicate symbols. Separate compilation is faster on a machine with cores to spare and is what a
rem real build system should do; this is the fallback for someone with none.
set "GENERATED="
for /f "tokens=1 delims=," %%f in ('findstr /r /c:"\.c\"" "%CDIR%\hlc.json"') do (
	if not defined GENERATED (
		set "ONE=%%f"
		set "ONE=!ONE:"=!"
		set "ONE=!ONE: =!"
		set "ONE=!ONE:	=!"
		if not "!ONE!"=="" set "GENERATED="%CDIR%\!ONE!""
	)
)

if not defined GENERATED (
	echo hlc.json in %CDIR% names no files 1>&2
	exit /b 1
)

rem A HashLink install ships one .hdll per library, and hlc.json names them the way @:hlNative did,
rem so the two line up. std is libhl itself, and hxscript is compiled in from source rather than
rem linked against, which is what makes the result one binary with nothing to ship beside it.
set "LINK="%HL%\libhl.dll""

for /f "delims=" %%l in ('findstr /r /c:"\"libs\"" "%CDIR%\hlc.json"') do (
	set "LINE=%%l"
	set "LINE=!LINE:"libs"=!"
	set "LINE=!LINE:[=!"
	set "LINE=!LINE:]=!"
	set "LINE=!LINE::=!"
	set "LINE=!LINE:"=!"
	for %%n in (!LINE!) do (
		if not "%%n"=="std" if not "%%n"=="hxscript" (
			if exist "%HL%\%%n.hdll" set "LINK=!LINK! "%HL%\%%n.hdll""
		)
	)
)

set "LINK=!LINK! -ldbghelp -luser32 -lkernel32"

if not defined EXE set "EXE=%CDIR%\main.exe"

rem --- build -------------------------------------------------------------------------------------

echo building %EXE%
if "%JIT%"=="0" echo without the loader, so every script will be interpreted

rem -municode because hlc_main.c's entry point is wmain.
"%CC%" -O2 -municode !INCLUDES! -I"%CDIR%" -o "%EXE%" !GENERATED! !CARRIED! !LINK!
if errorlevel 1 exit /b 1

echo ok
exit /b 0

rem --- helpers -----------------------------------------------------------------------------------

:holds
if exist "%~1\libhl.dll" exit /b 0
if exist "%~1\libhl.lib" exit /b 0
exit /b 1

:istree
if not exist "%~1\src\hl.h" exit /b 1
if not exist "%~1\src\hlmodule.h" exit /b 1
if not exist "%~1\src\opcodes.h" exit /b 1
if not exist "%~1\src\code.c" exit /b 1
if not exist "%~1\src\module.c" exit /b 1
if not exist "%~1\src\jit.c" exit /b 1
exit /b 0

rem hl.h carries HL_VERSION as one byte each, so 0x011000 is 1.16.0.
:stamped
set "STAMPED="
if not exist "%~1" exit /b 0
set "RAW="
for /f "tokens=3" %%s in ('findstr /r /c:"^#[ 	]*define[ 	][ 	]*HL_VERSION" "%~1" 2^>nul') do if not defined RAW set "RAW=%%s"
if not defined RAW exit /b 0
set /a "MAJ=(%RAW%) >> 16 & 255, MIN=((%RAW%) >> 8) & 255, PAT=(%RAW%) & 255" 2>nul
set "STAMPED=%MAJ%.%MIN%.%PAT%"
exit /b 0

:fetch
echo.
echo No hashlink sources are on this machine, and they cannot be worked out: the binary
echo distributions ship hl.h and none of code.c, module.c or jit.c, which the loader is built from.
echo.

set "REPLY=n"
if "%YES%"=="1" (
	set "REPLY=y"
) else (
	set /p "REPLY=Fetch the hashlink %VERSION% sources from %REPO% ? [y/N] "
)

if /i not "%REPLY%"=="y" if /i not "%REPLY%"=="yes" (
	echo nothing was fetched. Get the hashlink %VERSION% sources and pass --src ^<directory^>, or pass --no-jit to build without the loader 1>&2
	exit /b 0
)

where curl.exe >nul 2>&1 || ( echo curl is needed to fetch them 1>&2 & exit /b 0 )
where tar.exe >nul 2>&1 || ( echo tar is needed to unpack them 1>&2 & exit /b 0 )

set "GOT=0"
for /f "tokens=1,2 delims=." %%a in ("%VERSION%") do set "SHORT=%%a.%%b"

for %%t in ("%VERSION%" "!SHORT!") do (
	if "!GOT!"=="0" (
		echo fetching %REPO%/archive/refs/tags/%%~t.tar.gz
		curl -fsSL -o "hashlink-src.tar.gz" "%REPO%/archive/refs/tags/%%~t.tar.gz" >nul 2>&1 && set "GOT=1"
	)
)

if "!GOT!"=="0" (
	echo could not fetch them. Download the hashlink %VERSION% sources yourself and pass --src 1>&2
	exit /b 0
)

if exist "hashlink-%VERSION%" rmdir /s /q "hashlink-%VERSION%"
mkdir "hashlink-%VERSION%"
tar -xzf "hashlink-src.tar.gz" -C "hashlink-%VERSION%" --strip-components=1
del /q "hashlink-src.tar.gz"

call :istree "hashlink-%VERSION%" || ( echo what was fetched is not a hashlink source tree 1>&2 & exit /b 0 )
for %%d in ("hashlink-%VERSION%") do set "SRC=%%~fd"
echo unpacked into !SRC!
exit /b 0
