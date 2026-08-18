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

/**
	Memory that can be written and then executed, and the cache maintenance that makes it run.

	libhl has `hl_alloc_executable_memory` and it cannot be used here. Off Windows it is a plain
	mmap asking for PROT_EXEC, which Apple Silicon refuses outright: a process there gets writable
	and executable pages only through MAP_JIT, only with the com.apple.security.cs.allow-jit
	entitlement, and only one of the two permissions at a time per thread. That is a per-OS problem
	rather than a hashlink one, so it is answered here rather than worked around at every call.

	The cache maintenance is not optional and not a detail. On x86 the instruction and data caches
	are coherent, so a jit writes bytes and jumps to them. On AArch64 they are not: freshly written
	code sits in the data cache while the instruction cache still holds whatever was at that address
	before, and executing it runs neither one thing nor the other. Every failure that causes looks
	random, moves when you add a printf, and is not random at all.
*/
#ifndef HXS_A64_EXEC_H
#define HXS_A64_EXEC_H

#include <stddef.h>

/**
	Reserves memory that can hold code.

	@param size How many bytes, rounded up to a page inside.
	@return The block, or NULL. It is writable when it comes back, and on a platform that enforces
	        W^X it is not yet executable: `hxs_exec_seal` is what makes it so.
*/
void *hxs_exec_alloc( size_t size );

/** Gives a block back. `size` has to be the size it was asked for. */
void hxs_exec_free( void *at, size_t size );

/**
	Makes a block executable and its contents visible to the processor as instructions.

	Both halves matter and they are separate things. Where W^X is enforced this drops the ability to
	write; everywhere it flushes the caches, which is what turns bytes that have been stored into
	instructions that will run.

	@param at The block.
	@param size Its size.
*/
void hxs_exec_seal( void *at, size_t size );

/**
	Makes a sealed block writable again, for patching code that is already running.

	Undone by sealing it again, which is what publishes the change. A platform with no W^X does
	nothing here, since its memory never stopped being writable.

	@param at The block.
	@param size Its size.
*/
void hxs_exec_unseal( void *at, size_t size );

/** @return Whether this build enforces W^X, so a caller can say why patching costs what it does. */
int hxs_exec_strict( void );

#endif
