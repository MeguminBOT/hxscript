@echo off
color 0a
rem SETUP FOR WINDOWS!!!
rem REMINDER THAT YOU NEED HAXE INSTALLED PRIOR TO USING THIS
rem https://haxe.org/download
rem
rem Installs everything apps\sandbox needs into a haxelib repository of its own, so nothing here
rem disturbs the libraries the rest of your machine builds against. Run it once, then build:
rem
rem     setup\windows.bat
rem     build.bat run
cd ..
setlocal enabledelayedexpansion

if not exist ".haxelib" (
	echo Creating local haxelib repository...
	call haxelib newrepo
)

echo.
echo Installing hxcpp from git first (so no haxelib installs outdated versions)...
echo.

call :installGit hxcpp https://github.com/HaxeFoundation/hxcpp v4.3.148

echo.
echo Installing haxelib dependencies (--skip-dependencies, all transitive deps are manually asserted)...
echo This might take a few moments depending on your internet speed.
echo.

call haxelib install lime          8.3.2  --quiet --always --skip-dependencies
call haxelib install openfl        9.5.2  --quiet --always --skip-dependencies
call haxelib install flixel        6.2.0  --quiet --always --skip-dependencies
call haxelib install flixel-addons 4.0.1  --quiet --always --skip-dependencies
call haxelib install flixel-ui     2.6.5  --quiet --always --skip-dependencies
call haxelib install hscript       2.7.0  --quiet --always --skip-dependencies

echo.
echo Installing git dependencies...
echo.

rem The interpreter this app exists to demonstrate. Its dev branch, not a release: the sandbox is
rem written against the library as it currently is.
call :installGit hxscript https://github.com/MeguminBOT/hxscript dev
rem The widget set the shell is built from. On haxelib as well, but tracked from source for the same
rem reason.
call :installGit smidr    https://github.com/MeguminBOT/SmidrUI

rem Building from a checkout of either repository rather than a release? Point haxelib at it and this
rem setup stays out of the way:
rem
rem     haxelib dev hxscript C:\path\to\hxscript
rem     haxelib dev smidr    C:\path\to\SmidrUI
rem
rem build.bat does exactly that when it finds a checkout beside this one.

echo.
echo Re-asserting hxcpp = 'git' just in case and wiping any release version that snuck in.
for /d %%V in (".haxelib\hxcpp\*") do (
	if /i not "%%~nxV"=="git" (
		echo Removing stray hxcpp version %%~nxV ...
		attrib -r -s -h "%%V\*.*" /s /d >nul 2>&1
		rmdir /s /q "%%V"
	)
)
call haxelib set hxcpp git --always

echo.
echo Building hxcpp command-line tool from source...
if exist ".haxelib\hxcpp\git\tools\hxcpp\compile.hxml" (
	pushd ".haxelib\hxcpp\git\tools\hxcpp"
	call haxe compile.hxml
	popd
)

echo.
echo Setting up lime...
call haxelib run lime setup -alias -y

echo.
echo Finished! Build the sandbox with:  build.bat run
endlocal
pause
exit /b 0

:installGit
rem %1 = library name, %2 = git url, %3 = optional git branch/commit to pin
rem Translate dots in lib name to commas for the on-disk folder (haxelib's encoding).
set "LIB_DIR=%~1"
set "LIB_DIR=!LIB_DIR:.=,!"
rem Wipe any leftover folder so haxelib never hits sys_remove_dir on read-only .git files.
if exist ".haxelib\!LIB_DIR!" (
	echo Cleaning existing .haxelib\!LIB_DIR! ...
	attrib -r -s -h ".haxelib\!LIB_DIR!\*.*" /s /d >nul 2>&1
	rmdir /s /q ".haxelib\!LIB_DIR!"
)
call haxelib git %~1 %~2 %~3 --skip-dependencies
exit /b 0
