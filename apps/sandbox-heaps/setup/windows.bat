@echo off
rem SETUP FOR WINDOWS
rem REMINDER THAT YOU NEED HAXE AND HASHLINK INSTALLED PRIOR TO USING THIS
rem https://haxe.org/download
rem https://hashlink.haxe.org
rem
rem Installs everything apps\sandbox-heaps needs into a haxelib repository of its own, so nothing
rem here disturbs the libraries the rest of your machine builds against. Run it once, then build:
rem
rem     setup\windows.bat
rem     build.bat run

cd /d "%~dp0.."

echo Setting up local haxelib repository ...
call haxelib newrepo

echo.
echo Installing haxelib dependencies...
echo This might take a few moments depending on your internet speed.

rem Heaps, and the two it needs. hlsdl rather than hldx because it is the same backend on all three
rem platforms; the sdl.hdll it binds to already ships with HashLink.
call haxelib install heaps    2.1.0  --quiet --always --skip-dependencies
call haxelib install format   3.8.0  --quiet --always --skip-dependencies
call haxelib install hlsdl    1.15.0 --quiet --always --skip-dependencies
call haxelib install hlopenal 1.5.0  --quiet --always --skip-dependencies

echo.
echo Installing git dependencies...
rem The interpreter this app exists to demonstrate. Its dev branch, not a release: the sandbox is
rem written against the library as it currently is.
call haxelib git hxscript https://github.com/MeguminBOT/hxscript dev --skip-dependencies

echo.
echo Building the HashLink extension...
rem What lets a compiled script run rather than only an interpreted one. It needs a hashlink source
rem tree matching your VM, and it offers to fetch one if this machine has none. Answering no is
rem fine: without the extension every script is interpreted, which costs speed and nothing else.
if exist "..\..\src\hxscript\hl\hdll.bat" (
	call "..\..\src\hxscript\hl\hdll.bat" --out export
) else (
	echo No checkout of hxscript here, so the extension was skipped.
	echo Run: haxelib run hxscript hdll export
)

echo.
echo Finished! Build the sandbox with:  build.bat run
