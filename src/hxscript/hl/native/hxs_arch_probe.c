/*
	What the build preprocesses to find out which architecture the compiler in front of it is
	targeting. Not compiled, and not valid C: `cc -E` on this prints one line naming the answer,
	which is read back by build.sh and by hxscript.setup.Native.

	Asking the compiler is what makes cross compiling work. A target triple would have to be parsed
	and would still miss `-arch arm64` on macOS, where one clang builds for either.
*/
#include "hxs_arch.h"

hxs_arch HXS_ARCH_NAME HXS_ARCH_HAS_JIT
