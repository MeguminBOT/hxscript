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

rem There is no step here for the script compiler, and that is the difference this app is built to
rem show. A HashLink program running on the VM gets one as a .hdll placed beside it, which is a file
rem that can be there or not and a decision made after the build. This one is a native binary: the
rem loader, the jit and hxScript's runtime are compiled into the executable by build.bat, along with
rem everything else. Nothing to install, nothing to ship beside it, and nothing that can go missing.

echo.
echo Finished! Build the sandbox with:  build.bat run
