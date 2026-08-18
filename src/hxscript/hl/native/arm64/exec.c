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

#include "exec.h"

#include <sys/mman.h>
#include <unistd.h>

#if defined(__APPLE__)
#	include <pthread.h>
#	include <libkern/OSCacheControl.h>
#endif

/**
	Whether writing and executing are two states of one page rather than two permissions it holds.

	Apple Silicon is the platform that enforces this. A thread there holds one or the other, swapped
	with pthread_jit_write_protect_np, and the pages have to have been asked for with MAP_JIT in the
	first place or they cannot be either.
*/
#if defined(__APPLE__) && defined(__aarch64__)
#	define HXS_EXEC_WX	1
#else
#	define HXS_EXEC_WX	0
#endif

/**
	MAP_JIT is Apple's, and asking for it anywhere else is asking for MAP_FAILED. Spelled here rather
	than at the call so the mmap below reads the same on every platform.
*/
#if HXS_EXEC_WX
#	define HXS_MAP_JIT	MAP_JIT
#else
#	define HXS_MAP_JIT	0
#endif

#ifndef MAP_ANONYMOUS
#	define MAP_ANONYMOUS MAP_ANON
#endif

/** @return `size` rounded up to a whole number of pages, which is the unit mmap deals in. */
static size_t hxs_exec_pages( size_t size ) {
	size_t page = (size_t)sysconf(_SC_PAGESIZE);

	if( page == 0 )
		page = 4096;

	return (size + page - 1) & ~(page - 1);
}

void *hxs_exec_alloc( size_t size ) {
	void *at;

	if( size == 0 )
		return NULL;

	at = mmap(NULL, hxs_exec_pages(size), PROT_READ | PROT_WRITE | PROT_EXEC,
		MAP_PRIVATE | MAP_ANONYMOUS | HXS_MAP_JIT, -1, 0);

	if( at == MAP_FAILED )
		return NULL;

	return at;
}

void hxs_exec_free( void *at, size_t size ) {
	if( at != NULL )
		munmap(at, hxs_exec_pages(size));
}

void hxs_exec_seal( void *at, size_t size ) {
	if( at == NULL || size == 0 )
		return;

#if HXS_EXEC_WX
	pthread_jit_write_protect_np(1);
	sys_icache_invalidate(at, size);
#else
	/**
		The compiler knows the sequence this architecture needs, which is a data cache clean by
		address followed by an instruction cache invalidate and a barrier. Writing it out by hand
		would be writing out what the compiler already emits, and getting it wrong is invisible
		until something runs stale code.
	*/
	__builtin___clear_cache((char *)at, (char *)at + size);
#endif
}

void hxs_exec_unseal( void *at, size_t size ) {
	(void)at;
	(void)size;

#if HXS_EXEC_WX
	pthread_jit_write_protect_np(0);
#endif
}

int hxs_exec_strict( void ) {
	return HXS_EXEC_WX;
}
