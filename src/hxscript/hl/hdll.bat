@echo off
rem Builds hxscript.hdll, the extension a HashLink host needs to run compiled scripts.
rem
rem   hdll.bat                     ask about anything it cannot work out
rem   hdll.bat --out bin           put it somewhere in particular
rem   hdll.bat --out bin --yes     answer yes to everything, for a build machine
rem
rem Everything it can work out from this machine it works out: where HashLink is, which version,
rem where a matching source tree is, and which C compiler to drive. The one thing it cannot is the
rem hashlink sources when the machine has none, because the binary distributions ship hl.h and none
rem of the rest. It asks before fetching those, and does nothing you did not agree to.
rem
rem Nothing here needs Haxe. A build with `-lib hxscript -D hxscript_hl` does the same work by
rem itself, minus the fetching, which is why this exists separately.

setlocal enabledelayedexpansion

set "HERE=%~dp0"
set "HERE=%HERE:~0,-1%"
set "OUT="
set "HL=%HLPATH%"
set "SRC=%HL_SRC%"
set "YES=0"
set "REPO=https://github.com/HaxeFoundation/hashlink"

:args
if "%~1"=="" goto args_done
if /i "%~1"=="--out" ( set "OUT=%~2" & shift & shift & goto args )
if /i "%~1"=="--hl" ( set "HL=%~2" & shift & shift & goto args )
if /i "%~1"=="--src" ( set "SRC=%~2" & shift & shift & goto args )
if /i "%~1"=="--yes" ( set "YES=1" & shift & goto args )
if /i "%~1"=="-y" ( set "YES=1" & shift & goto args )
if /i "%~1"=="--help" goto usage
if /i "%~1"=="-h" goto usage
if not defined OUT ( set "OUT=%~1" & shift & goto args )
echo unknown argument: %~1 1>&2
exit /b 1

:usage
for /f "tokens=1,* delims=:" %%a in ('findstr /n "^rem" "%~f0"') do @echo(%%b
exit /b 0

:args_done

rem --- where to put it ---------------------------------------------------------------------------

if not defined OUT (
	if "%YES%"=="0" set /p "OUT=Where should hxscript.hdll go? [.] "
)
if not defined OUT set "OUT=."
if not exist "%OUT%" mkdir "%OUT%"
for %%d in ("%OUT%") do set "OUT=%%~fd"

rem --- the VM ------------------------------------------------------------------------------------

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

set "HLEXE=%HL%\hl.exe"
if not exist "%HLEXE%" set "HLEXE=hl"

set "VERSION="
for /f "delims=" %%v in ('"%HLEXE%" --version 2^>nul') do if not defined VERSION set "VERSION=%%v"

if not defined VERSION (
	echo the HashLink at %HL% would not report its version 1>&2
	exit /b 1
)

echo HashLink %VERSION% at %HL%

rem --- the sources -------------------------------------------------------------------------------

if defined SRC call :istree "%SRC%" || ( echo no hashlink sources in %SRC% 1>&2 & exit /b 1 )

if not defined SRC (
	for %%n in ("%HL%\src" "%HL%\.." "%HL%\..\src" "%HL%\..\.." "hashlink-%VERSION%") do (
		if not defined SRC call :istree "%%~fn" && set "SRC=%%~fn"
	)
)

if not defined SRC call :fetch
if not defined SRC exit /b 1

rem --- do they match -----------------------------------------------------------------------------

rem hl.h carries the version it belongs to, and its struct layouts are shared with the running
rem libhl, so a mismatched pair compiles and links cleanly and then reads fields from the wrong
rem offsets.
set "STAMP="
for /f "tokens=3" %%s in ('findstr /r /c:"^#[ 	]*define[ 	][ 	]*HL_VERSION" "%SRC%\src\hl.h" 2^>nul') do if not defined STAMP set "STAMP=%%s"

if defined STAMP (
	set /a "MAJ=(%STAMP%) >> 16, MIN=((%STAMP%) >> 8) & 255, PAT=(%STAMP%) & 255" 2>nul
	if not "!MAJ!.!MIN!.!PAT!"=="%VERSION%" (
		echo the sources in %SRC% are hashlink !MAJ!.!MIN!.!PAT! and the VM is %VERSION%. Pass --src for a matching tree. 1>&2
		exit /b 1
	)
)

echo sources at %SRC%

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

rem --- build -------------------------------------------------------------------------------------

rem gc.c and allocator.c are deliberately NOT carried: they are already in the running libhl, and a
rem second copy would give loaded modules their own heap, leaving their objects invisible to its
rem collector.
echo building %OUT%\hxscript.hdll

rem Named only once it is whole, so an interrupted build cannot leave something that loads.
"%CC%" -O2 -shared -m64 -I"%SRC%\src" -I"%HERE%" -o "%OUT%\hxscript.hdll.building" "%HERE%\hxscript.c" "%SRC%\src\code.c" "%SRC%\src\module.c" "%SRC%\src\jit.c" "%HL%\libhl.dll"
if errorlevel 1 exit /b 1

move /y "%OUT%\hxscript.hdll.building" "%OUT%\hxscript.hdll" >nul
echo %VERSION%> "%OUT%\hxscript.hdll.built"

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

:fetch
echo.
echo No hashlink sources are on this machine, and they cannot be worked out: the binary
echo distributions ship hl.h and none of code.c, module.c or jit.c, which this is built from.
echo.

set "REPLY=n"
if "%YES%"=="1" (
	set "REPLY=y"
) else (
	set /p "REPLY=Fetch the hashlink %VERSION% sources from %REPO% ? [y/N] "
)

if /i not "%REPLY%"=="y" if /i not "%REPLY%"=="yes" (
	echo nothing was fetched. Get the hashlink %VERSION% sources and pass --src ^<directory^> 1>&2
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
