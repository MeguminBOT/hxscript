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
	Whether this build carries the loader at all.

	Decided before hl.h is included, and it has to be: something hl.h reaches defines the compiler's
	own architecture macros back again, so a test written after it is answered by the header rather
	than by the machine being built for.

	HashLink's jit emits x86 and x86-64 machine code and nothing else. jit.c says so itself, but only
	for 32-bit ARM, and its test is `__arm__`, which arm64 does not define: on arm64 it compiles
	cleanly and writes x86 bytes into executable memory. hashlink's own Makefile is the plainer
	statement of the same fact, since it skips building the VM there entirely:

	    ifeq ($(ARCH),arm64)
	        $(warning HashLink vm is not supported on arm64, skipping)

	So the loader is compiled only where it can work, and everything below still exists everywhere.
	Every native stays defined either way, which is what lets a host on any architecture link against
	this file unchanged; on one without the loader they answer that they cannot help, the library
	reports itself unusable, and every script is interpreted. That is the same answer, by the same
	path, that a HashLink host already gets when the extension is not there at all.

	Where this is not defined, code.c, module.c and jit.c do not need to be compiled or linked.
	`-DHXS_NO_JIT` asks for that build on a machine that could have had the loader, which is how it
	is tested on one and is also the smaller binary for a host that only ever wants the interpreter.
*/
#if !defined(HXS_NO_JIT)
#	if defined(__x86_64__) || defined(__amd64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#		define HXS_LOADER
#	endif
#endif

#define HL_NAME(n) hxscript_##n
#include <hl.h>
#include <string.h>

/*
	The carried loader against the hl.h this is being built with.

	The loader is not a caller of libhl, it shares structures with it: the jit compiled in here emits
	machine code carrying literal byte offsets into objects libhl allocates, and those offsets come
	from whichever hl.h this saw. Carrying hashlink 1.16's loader and building it against another
	hashlink's headers is the mismatch that produces a clean build and a wrong field.

	So the pairing is checked here, where it can still be acted on, and a build that would have been
	wrong becomes a build that interprets instead. HL_SRC defines HXS_HL_ANY_VERSION, because there
	the loader sources came from the same tree as the headers and this test is not about them.
*/
#if defined(HXS_LOADER) && !defined(HXS_HL_ANY_VERSION)
#	ifndef HXS_HL_VERSION
#		define HXS_HL_VERSION 0x011000
#	endif
#	if HL_VERSION != HXS_HL_VERSION
#		undef HXS_LOADER
#		define HXS_WRONG_VERSION
#	endif
#endif

/** Why the loader cannot be used, as `state` reports it. */
#define HXS_STATE_USABLE	0
#define HXS_STATE_NO_LOADER	1
#define HXS_STATE_DISAGREES	2

#ifdef HXS_LOADER

#include <hlmodule.h>

/*
	Loading emitted bytecode into a running HashLink process.

	HashLink's loader is compiled into hl.exe rather than libhl, so a host has no way to reach it.
	This module carries hashlink's own code.c, module.c and jit.c and calls them, which keeps the VM
	stock: a host ships this .hdll beside the others and runs `hl game.hl` as before.

	Nothing here allocates its own heap. gc.c and allocator.c stay in libhl, so a module loaded
	through this one shares the host's memory and its collector rather than getting a second one that
	the first cannot see.

	The same file is what an HL/C program compiles in. There it is linked rather than loaded, and the
	header Haxe generates for its natives declares exactly the symbols defined below, so nothing
	about it changes between the two ways of shipping.
*/

typedef struct {
	void (*finalize)(void *);
	hl_module *m;
	hl_code *code;
} hxs_module;

/** The last failure's message, for a host that wants to report rather than guess. */
static char *hxs_last_error = NULL;

/*
	Keeping a loaded module alive.

	What a host holds after loading is a closure over one of the module's functions, and a closure is
	a code pointer with no reference back to the module that owns the code. Left to the collector,
	the module is unreachable the moment the handle goes out of scope, and freeing it unmaps the very
	machine code something is about to call.

	So a module is held here for the life of the process. The slots are rooted where they sit and the
	array grows by whole blocks that are never moved, because hl_add_root records the address of a
	slot: reallocating would leave the collector tracing memory that had been freed.
*/
#define HXS_HELD_PER_BLOCK 32

typedef struct hxs_held hxs_held;

struct hxs_held {
	hxs_module *slots[HXS_HELD_PER_BLOCK];
	int used;
	hxs_held *next;
};

static hxs_held *hxs_held_blocks = NULL;

static void hxs_hold( hxs_module *h ) {
	hxs_held *b = hxs_held_blocks;
	if( b == NULL || b->used == HXS_HELD_PER_BLOCK ) {
		b = (hxs_held*)calloc(1,sizeof(hxs_held));
		if( b == NULL ) return;
		b->next = hxs_held_blocks;
		hxs_held_blocks = b;
	}
	b->slots[b->used] = h;
	hl_add_root((void**)&b->slots[b->used]);
	b->used++;
}

/*
	Giving the host back the two hooks hl_module_init takes.

	hl_module_init ends by pointing hl_setup.resolve_symbol and hl_setup.capture_stack at its own
	module.c statics, which is correct for hl.exe, where that copy of module.c is the only one there
	is. Here it is not: the host has its own walker, either hl.exe's copy over the host's own modules
	or, in an HL/C binary, hlc_capture_stack over real native frames. Letting ours win would silently
	empty the host's exception stack traces, which is the kind of breakage a host would find months
	later and never attribute to having enabled scripting.

	The walker is handed straight back, because only the host's can see the host's frames. The
	resolver is chained instead: ours knows the addresses inside jitted script code and answers NULL
	for everything else, so asking it first and the host's second names both. On HL/C that gives a
	trace with script frames in it, since there the host's walker captured every frame there was.

	hl_gc_set_dump_types is left as hl_module_init set it. There is no way to read the previous one
	back, so it cannot be chained, and what it costs is bounded: a memory dump names the types of
	modules loaded through here rather than the host's.
*/
static uchar *(*hxs_host_resolve)( void *, uchar *, int * ) = NULL;
static uchar *(*hxs_module_resolve)( void *, uchar *, int * ) = NULL;

static uchar *hxs_resolve_symbol( void *addr, uchar *out, int *outSize ) {
	int size = *outSize;
	if( hxs_module_resolve ) {
		uchar *found = hxs_module_resolve(addr,out,outSize);
		if( found ) return found;
		*outSize = size;
	}
	return hxs_host_resolve ? hxs_host_resolve(addr,out,outSize) : NULL;
}

/*
	Where a script module's own natives come from.

	Called by the one patched line in module.c, before hashlink looks for an hdll. Compiled scripts
	reach hxScript's runtime through natives in a library named `hxs`, which is no library at all: it
	is this binary, and on HL/C there is no hdll in the process to find anything in.

	Resolving them to function pointers here is also what makes them fast. A native the module
	declares is called by jitted code the way any C function is called, with its arguments in
	registers and its real signature, which is the whole reason the runtime is written in C rather
	than reached as a Haxe closure through a boxed argument list.

	Anything not claimed here goes back to hashlink's own path, so a script module may still name a
	real hdll.
*/
typedef struct {
	const char *name;
	void *fn;
} hxs_native;

static hxs_native hxs_native_table[] = {
	{ NULL, NULL }
};

void *hxs_resolve_native( const char *lib, const char *name ) {
	int i;
	if( strcmp(lib,"hxs") != 0 )
		return NULL;
	for(i=0;hxs_native_table[i].name;i++)
		if( strcmp(hxs_native_table[i].name,name) == 0 )
			return hxs_native_table[i].fn;
	return NULL;
}

static void hxs_module_finalize( hxs_module *h ) {
	if( h->m ) {
		hl_module_free(h->m);
		h->m = NULL;
	}
	if( h->code ) {
		hl_code_free(h->code);
		h->code = NULL;
	}
}

/*
	Whether this was built against the same hashlink the VM is running.

	The version test above is the compile time half of this question and cannot be the whole of it: a
	build carries the hl.h it was handed, and nothing checks that libhl was built from the same one.
	The compiler only ever sees the headers it was given, and the linker matches names rather than
	layouts, so a mismatched pair builds cleanly and then reads a field from the wrong place.

	libhl publishes no version to compare against, so the layouts are tested instead of trusted:
	values are put through libhl's own allocators and read back at the offsets this build believes
	in. Cheap, and it fails where the mistake is rather than somewhere unrelated later.
*/
static bool hxs_layouts_agree( void ) {
	vclosure *c;
	varray *a;
	vdynamic *d;

	c = hl_alloc_closure_void(&hlt_dyn, (void *)&hlt_i32);
	if( c == NULL || c->t != &hlt_dyn || c->fun != (void *)&hlt_i32 || c->hasValue != 0 )
		return false;

	a = hl_alloc_array(&hlt_i32, 3);
	if( a == NULL || a->at != &hlt_i32 || a->size != 3 )
		return false;

	d = hl_alloc_dynamic(&hlt_i32);
	if( d == NULL || d->t != &hlt_i32 )
		return false;

	d->v.i = 0x5A5A5A5A;
	if( hl_dyn_casti(&d, &hlt_dyn, &hlt_i32) != 0x5A5A5A5A )
		return false;

	return true;
}

/**
	Reads, links and jits a module.

	@return An opaque handle, or NULL when it could not be read; `last_error` then says why.
*/
HL_PRIM hxs_module *HL_NAME(load)( vbyte *data, int size ) {
	hl_code *code;
	hl_module *m;
	hxs_module *h;
	uchar *(*before_resolve)( void *, uchar *, int * );
	int (*before_capture)( void **, int );

	hxs_last_error = NULL;

	code = hl_code_read((const unsigned char *)data, size, &hxs_last_error);
	if( code == NULL )
		return NULL;

	m = hl_module_alloc(code);
	if( m == NULL ) {
		hl_code_free(code);
		hxs_last_error = "could not allocate the module";
		return NULL;
	}

	before_resolve = hl_setup.resolve_symbol;
	before_capture = hl_setup.capture_stack;

	if( !hl_module_init(m, false) ) {
		hl_setup.resolve_symbol = before_resolve;
		hl_setup.capture_stack = before_capture;
		hl_module_free(m);
		hl_code_free(code);
		hxs_last_error = "could not link the module";
		return NULL;
	}

	hxs_module_resolve = hl_setup.resolve_symbol;
	if( hxs_host_resolve == NULL && before_resolve != hxs_resolve_symbol )
		hxs_host_resolve = before_resolve;
	hl_setup.resolve_symbol = hxs_resolve_symbol;
	hl_setup.capture_stack = before_capture;

	h = (hxs_module *)hl_gc_alloc_finalizer(sizeof(hxs_module));
	h->finalize = (void (*)(void *))hxs_module_finalize;
	h->m = m;
	h->code = code;
	hxs_hold(h);
	return h;
}

/** @return The function index the module names as its entry point. */
HL_PRIM int HL_NAME(entry_index)( hxs_module *h ) {
	return h == NULL ? -1 : h->code->entrypoint;
}

/**
	Wraps one of the module's functions as an ordinary Haxe function value.

	This is what lets a compiled script stand in for an interpreted one without the interpreter
	knowing: what comes back is a closure like any other.
*/
HL_PRIM vclosure *HL_NAME(closure)( hxs_module *h, int findex ) {
	hl_type *t;
	void *fun;

	if( h == NULL || findex < 0 || findex >= h->code->nfunctions + h->code->nnatives )
		return NULL;

	t = h->code->functions[h->m->functions_indexes[findex]].type;
	fun = h->m->functions_ptrs[findex];
	if( fun == NULL )
		return NULL;

	return hl_alloc_closure_void(t, fun);
}

/**
	Puts a value in one of a loaded module's globals.

	This is how compiled code reaches a value the host already holds: the emitter leaves a global for
	each one a script names, and these are filled once after loading rather than looked up per call.
	Only a pointer-typed global may be written, which is every global the emitter makes, because
	hl_module_init roots exactly those and a value written anywhere else would be invisible to the
	collector.
*/
HL_PRIM void HL_NAME(set_global)( hxs_module *h, int index, vdynamic *value ) {
	hl_type *t;

	if( h == NULL || index < 0 || index >= h->code->nglobals )
		return;

	t = h->code->globals[index];
	if( !hl_is_ptr(t) )
		return;

	*(vdynamic **)(h->m->globals_data + h->m->globals_indexes[index]) = value;
}

/** @return Why the loader cannot be used, or HXS_STATE_USABLE when it can. */
HL_PRIM int HL_NAME(state)( void ) {
	return hxs_layouts_agree() ? HXS_STATE_USABLE : HXS_STATE_DISAGREES;
}

HL_PRIM vbyte *HL_NAME(last_error)( void ) {
	return (vbyte *)hxs_last_error;
}

#else

/*
	The same natives on a build that carries no loader.

	They exist so that the link is the same everywhere and a host has one thing to ask rather than
	two. What they answer is that there is no loader here, which the library already knows how to act
	on: `Loader.available` is false, `Compiler.available` is false, and scripts are interpreted.
*/

typedef struct {
	void (*finalize)(void *);
} hxs_module;

HL_PRIM hxs_module *HL_NAME(load)( vbyte *data, int size ) {
	return NULL;
}

HL_PRIM int HL_NAME(entry_index)( hxs_module *h ) {
	return -1;
}

HL_PRIM vclosure *HL_NAME(closure)( hxs_module *h, int findex ) {
	return NULL;
}

HL_PRIM void HL_NAME(set_global)( hxs_module *h, int index, vdynamic *value ) {
}

HL_PRIM int HL_NAME(state)( void ) {
	return HXS_STATE_NO_LOADER;
}

HL_PRIM vbyte *HL_NAME(last_error)( void ) {
#ifdef HXS_WRONG_VERSION
	return (vbyte *)"the carried loader is for a different hashlink than this build's hl.h";
#else
	return (vbyte *)"this build carries no loader, because HashLink's jit is x86 and x86-64 only";
#endif
}

#endif

/** @return Whether the loader is here and agrees with the libhl it is running against. */
HL_PRIM bool HL_NAME(agrees)( void ) {
	return HL_NAME(state)() == HXS_STATE_USABLE;
}

/** @return The hashlink this was built against, for a host that wants to say so in a report. */
HL_PRIM int HL_NAME(built_for)( void ) {
	return HL_VERSION;
}

DEFINE_PRIM(_BOOL, agrees, _NO_ARG);
DEFINE_PRIM(_I32, state, _NO_ARG);
DEFINE_PRIM(_I32, built_for, _NO_ARG);
DEFINE_PRIM(_BYTES, last_error, _NO_ARG);
DEFINE_PRIM(_VOID, set_global, _ABSTRACT(hxs_module) _I32 _DYN);
DEFINE_PRIM(_ABSTRACT(hxs_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, entry_index, _ABSTRACT(hxs_module));
DEFINE_PRIM(_DYN, closure, _ABSTRACT(hxs_module) _I32);
