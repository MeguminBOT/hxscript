/*
 * Copyright (c) 2026 MeguminBOT (hxScript)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
	Which architecture a build of the native module is for, and whether the carried loader can be
	compiled for it.

	This is a header of its own for two reasons. It has to be decided before hl.h is included, since
	hl.h defines the architecture macros back again; and the build has to know the same answer before
	it can decide what to compile, which it works out by preprocessing hxs_arch_probe.c beside this
	with the compiler and the flags it is about to use, rather than by reading a target triple and
	guessing. One chain, asked twice, so the two cannot drift apart.

	Only 64 bit is named. hashlink's jit can compile for 32 bit x86 as well, and this library does not
	go there: nothing is built or tested for it, so it reads as an architecture with no loader and
	interprets, which is the same answer every other unnamed one gets.
*/
#ifndef HXS_ARCH_H
#define HXS_ARCH_H

#define HXS_ARCH_UNKNOWN	0
#define HXS_ARCH_X86_64		1
#define HXS_ARCH_ARM64		2

/*
	ARM64EC is asked first because MSVC defines _M_X64 for it as well, to let x64 sources compile
	unchanged. A chain that took the first match would decide an ARM64EC build was x86-64, compile
	the x86 jit into it, and then jump into the machine code that produced.
*/
#if defined(_M_ARM64EC) || defined(__aarch64__) || defined(_M_ARM64) || defined(__arm64__)
#	define HXS_ARCH HXS_ARCH_ARM64
#	define HXS_ARCH_NAME "arm64"
#elif defined(__x86_64__) || defined(__amd64__) || defined(_M_X64) || defined(_M_AMD64)
#	define HXS_ARCH HXS_ARCH_X86_64
#	define HXS_ARCH_NAME "x86-64"
#else
#	define HXS_ARCH HXS_ARCH_UNKNOWN
#	define HXS_ARCH_NAME "neither x86-64 nor arm64"
#endif

/*
	Whether a loader can be compiled for this architecture, and whose jit it uses.

	Two answers rather than one, because the two supported architectures do not share a backend.
	x86-64 uses the jit hashlink ships, carried in vendor/. arm64 uses this library's own, in arm64/,
	because hashlink has none: its jit.c guards itself with __arm__, which 64 bit ARM does not define,
	so left to itself it compiles, emits x86, and on Windows does not get that far.

	HXS_ARCH_JIT names the directory, and the build reads it out of the probe rather than deciding for
	itself, so which backend a build uses is decided in one place.
*/
#if HXS_ARCH == HXS_ARCH_X86_64
#	define HXS_ARCH_HAS_JIT 1
#	define HXS_ARCH_JIT "vendor"
#elif HXS_ARCH == HXS_ARCH_ARM64
#	define HXS_ARCH_HAS_JIT 1
#	define HXS_ARCH_JIT "arm64"
#else
#	define HXS_ARCH_HAS_JIT 0
#	define HXS_ARCH_JIT "none"
#endif

#endif
