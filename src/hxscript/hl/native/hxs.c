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
	Giving the host back everything loading a module takes from it.

	Loading writes to hl_setup, which is libhl's one table of how this process resolves symbols, walks
	stacks, makes dynamic calls and unwinds out of a throw. module.c takes resolve_symbol and
	capture_stack at the end of hl_module_init, and jit.c takes get_wrapper, static_call,
	static_call_ref and throw_jump the first time it produces code. In hl.exe both of those happen at
	startup for the program's own module and never again; here the same code runs against a host that
	already had all of it set up, and every one of those fields is something the host's own code is
	using.

	Naming the six and patching them would leave this one version behind whenever hashlink takes a
	seventh, and the failure would be silent, which is the whole character of this class of bug. So
	the whole struct is copied before the load and put back afterwards, and then only what we mean to
	change is applied on top. A field nobody here has heard of goes back to what the host had, and
	`hooks` reports it so a test fails rather than a user does.

	What is deliberately not put back:

	`resolve_symbol` is chained. Ours knows the addresses inside jitted script code and answers NULL
	for anything else, so asking ours and then the host's names frames from both.

	`capture_stack` is handed straight back, because only the host's can see the host's frames. Ours
	walks cur_modules in this copy, which holds script modules and nothing else.

	`static_call` becomes a dispatcher. This is the one that matters most on HL/C, where the host's is
	the generated hlc_static_call and is how every dynamic call in the program works. Ours looks at
	the function being called, sends it to the jit's bridge when it is inside a module loaded here,
	and to the host's otherwise. static_call_ref differs between the two, so this always advertises
	the jit's convention and normalises before handing on.

	`get_wrapper` asks the host's first and falls back to the jit's, so a signature the host already
	had a wrapper for is wrapped exactly as it was before, and one it never generated can still be
	built rather than failing.

	`throw_jump` is where an exception lands after unwinding. The host's is put back when it had one,
	since on the VM both copies are the same code from the same version. When the host had none, or
	had the C library's longjmp, the jit's is kept: on 64-bit Windows a plain longjmp cannot return
	into a frame that jitted code owns, which is why hashlink generates its own, and hl.exe installs
	that one globally for C and jitted frames alike.

	hl_gc_set_dump_types is not in hl_setup and cannot be read back, so the patched module.c does not
	call it at all. A memory dump then names what it named before, and not the types of modules loaded
	here.
*/
static hl_setup_t hxs_setup_before;
static int hxs_setup_taken = 0;

/** Fields of hl_setup this expects a load to take, by bit. */
#define HXS_HOOK_THROW_JUMP		1
#define HXS_HOOK_RESOLVE		2
#define HXS_HOOK_CAPTURE		4
#define HXS_HOOK_STATIC_CALL	8
#define HXS_HOOK_GET_WRAPPER	16
#define HXS_HOOK_CALL_REF		32
#define HXS_HOOK_VTUNE			64

/** A field of hl_setup this has never heard of was taken, and was given back. */
#define HXS_HOOK_OTHER			128

static uchar *(*hxs_host_resolve)( void *, uchar *, int * ) = NULL;
static uchar *(*hxs_module_resolve)( void *, uchar *, int * ) = NULL;

static void *(*hxs_host_static_call)( void *, hl_type *, void **, vdynamic * ) = NULL;
static void *(*hxs_jit_static_call)( void *, hl_type *, void **, vdynamic * ) = NULL;
static bool hxs_host_static_call_ref = false;

static void *(*hxs_host_get_wrapper)( hl_type * ) = NULL;
static void *(*hxs_jit_get_wrapper)( hl_type * ) = NULL;

static uchar *hxs_resolve_symbol( void *addr, uchar *out, int *outSize ) {
	int size = *outSize;
	if( hxs_module_resolve ) {
		uchar *found = hxs_module_resolve(addr,out,outSize);
		if( found ) return found;
		*outSize = size;
	}
	return hxs_host_resolve ? hxs_host_resolve(addr,out,outSize) : NULL;
}

/** Whether an address is machine code a module loaded here owns. */
static bool hxs_owns_code( void *p ) {
	hxs_held *b = hxs_held_blocks;
	while( b ) {
		int i;
		for(i=0;i<b->used;i++) {
			hxs_module *h = b->slots[i];
			unsigned char *start;
			if( h == NULL || h->m == NULL || h->m->jit_code == NULL ) continue;
			start = (unsigned char*)h->m->jit_code;
			if( (unsigned char*)p >= start && (unsigned char*)p < start + h->m->codesize )
				return true;
		}
		b = b->next;
	}
	return false;
}

static void *hxs_static_call( void *f, hl_type *t, void **args, vdynamic *out ) {
	void *target = *(void**)f;

	if( hxs_jit_static_call && hxs_owns_code(target) )
		return hxs_jit_static_call(f,t,args,out);

	if( hxs_host_static_call )
		return hxs_host_static_call(hxs_host_static_call_ref ? f : target,t,args,out);

	return hxs_jit_static_call ? hxs_jit_static_call(f,t,args,out) : NULL;
}

static void *hxs_get_wrapper( hl_type *t ) {
	if( hxs_host_get_wrapper ) {
		void *w = hxs_host_get_wrapper(t);
		if( w ) return w;
	}
	return hxs_jit_get_wrapper ? hxs_jit_get_wrapper(t) : NULL;
}

/** Copies hl_setup as the host had it, before anything of ours writes to it. */
static void hxs_setup_snapshot( void ) {
	hxs_setup_before = hl_setup;
}

/**
	Puts the host's hl_setup back, then applies what this deliberately changes.

	Restoring first rather than patching in place is the point: whatever a future hashlink starts
	taking is given back without this file having heard of it, and shows up in `hooks` instead of in
	somebody's crash.
*/
static void hxs_setup_reconcile( void ) {
	hl_setup_t taken = hl_setup;
	int changed = 0;

	if( taken.throw_jump != hxs_setup_before.throw_jump ) changed |= HXS_HOOK_THROW_JUMP;
	if( taken.resolve_symbol != hxs_setup_before.resolve_symbol ) changed |= HXS_HOOK_RESOLVE;
	if( taken.capture_stack != hxs_setup_before.capture_stack ) changed |= HXS_HOOK_CAPTURE;
	if( taken.static_call != hxs_setup_before.static_call ) changed |= HXS_HOOK_STATIC_CALL;
	if( taken.get_wrapper != hxs_setup_before.get_wrapper ) changed |= HXS_HOOK_GET_WRAPPER;
	if( taken.static_call_ref != hxs_setup_before.static_call_ref ) changed |= HXS_HOOK_CALL_REF;
	if( taken.vtune_init != hxs_setup_before.vtune_init ) changed |= HXS_HOOK_VTUNE;

	if( taken.file_path != hxs_setup_before.file_path
		|| taken.sys_args != hxs_setup_before.sys_args
		|| taken.sys_nargs != hxs_setup_before.sys_nargs
		|| taken.reload_check != hxs_setup_before.reload_check
		|| taken.profile_event != hxs_setup_before.profile_event
		|| taken.before_exit != hxs_setup_before.before_exit
		|| taken.load_plugin != hxs_setup_before.load_plugin
		|| taken.resolve_type != hxs_setup_before.resolve_type
		|| taken.closure_stack_capture != hxs_setup_before.closure_stack_capture
		|| taken.is_debugger_enabled != hxs_setup_before.is_debugger_enabled
		|| taken.is_debugger_attached != hxs_setup_before.is_debugger_attached )
		changed |= HXS_HOOK_OTHER;

	hl_setup = hxs_setup_before;

	if( changed & HXS_HOOK_RESOLVE ) {
		hxs_module_resolve = taken.resolve_symbol;
		if( hxs_host_resolve == NULL && hxs_setup_before.resolve_symbol != hxs_resolve_symbol )
			hxs_host_resolve = hxs_setup_before.resolve_symbol;
		hl_setup.resolve_symbol = hxs_resolve_symbol;
	}

	if( changed & HXS_HOOK_STATIC_CALL ) {
		hxs_jit_static_call = taken.static_call;
		if( hxs_host_static_call == NULL && hxs_setup_before.static_call != hxs_static_call ) {
			hxs_host_static_call = hxs_setup_before.static_call;
			hxs_host_static_call_ref = hxs_setup_before.static_call_ref;
		}
		hl_setup.static_call = hxs_static_call;
		hl_setup.static_call_ref = true;
	}

	if( changed & HXS_HOOK_GET_WRAPPER ) {
		hxs_jit_get_wrapper = taken.get_wrapper;
		if( hxs_host_get_wrapper == NULL && hxs_setup_before.get_wrapper != hxs_get_wrapper )
			hxs_host_get_wrapper = hxs_setup_before.get_wrapper;
		hl_setup.get_wrapper = hxs_get_wrapper;
	}

	if( changed & HXS_HOOK_THROW_JUMP ) {
		void (*plain)( jmp_buf, int ) = (void (*)( jmp_buf, int ))longjmp;
		if( hxs_setup_before.throw_jump == NULL || hxs_setup_before.throw_jump == plain )
			hl_setup.throw_jump = taken.throw_jump;
	}

	hxs_setup_taken |= changed;
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

/*
	Reading and writing a field of something the script does not know the type of.

	This is the operation a real script spends its time on, and the one the previous attempt at this
	backend was slowest at: it emitted a call into a Haxe function taking Dynamic arguments, so every
	access boxed its arguments, called through a closure, and resolved the name by reflection with no
	memory of having done it before. A host field read came out at 2.2x interpreted where a typed
	local came out at 582x.

	HashLink already does better than that unaided. ODynGet compiles to a direct call to hl_dyn_getp
	with the name hashed at jit time, so the old backend was slower than the instruction it declined
	to use. What it still does per access is walk the object's field table, and its parent's, and its
	parent's, comparing hashes.

	The way past that is to remember. Every access the emitter writes gets a site of its own, and a
	site remembers the last receiver type it saw and where the field sat in it. A second access to the
	same shape is a pointer compare and a load at a constant offset, which is what cppia gets for free
	from compiling field access to a slot, and what this has to earn.

	A site that sees something other than a plain field of an object remembers that too, as an offset
	of -1, so an anonymous object or a virtual costs one compare before falling back to hashlink's own
	path rather than being resolved twice.
*/
typedef struct {
	hl_type *t;
	hl_type *ft;
	int offset;
} hxs_site;

static hxs_site *hxs_sites = NULL;
static int hxs_site_count = 0;
static int hxs_site_cap = 0;

/**
	@return A site index for the emitter to write into an access, or -1 when there is no memory.

	Handed out while a module is being written rather than after it loads, so the index is a constant
	in the bytecode and an access costs no indirection to find its own cache.
*/
HL_PRIM int HL_NAME(site)( void ) {
	if( hxs_site_count == hxs_site_cap ) {
		int cap = hxs_site_cap ? hxs_site_cap * 2 : 256;
		hxs_site *grown = (hxs_site*)realloc(hxs_sites,sizeof(hxs_site) * cap);
		if( grown == NULL ) return -1;
		hxs_sites = grown;
		hxs_site_cap = cap;
	}
	memset(hxs_sites + hxs_site_count,0,sizeof(hxs_site));
	return hxs_site_count++;
}

/**
	Where a field lives in a receiver, or NULL when this is not a plain field of an object.

	The resolution on a miss is hashlink's own, from obj_resolve_field: the lookup table of the type,
	then of its parent, until one of them has the hash. A negative field_index is a method rather than
	a field and is left to the slow path, which knows how to make a closure of it.
*/
static void *hxs_field( vdynamic *obj, int hash, int site, hl_type **ft ) {
	hxs_site *s;
	hl_runtime_obj *rt;

	if( obj == NULL || site < 0 || site >= hxs_site_count )
		return NULL;

	s = hxs_sites + site;

	if( s->t == obj->t ) {
		if( s->offset < 0 )
			return NULL;
		*ft = s->ft;
		return (char*)obj + s->offset;
	}

	if( obj->t->kind != HOBJ ) {
		s->t = obj->t;
		s->offset = -1;
		return NULL;
	}

	rt = hl_get_obj_rt(obj->t);
	while( rt ) {
		hl_field_lookup *f = hl_lookup_find(rt->lookup,rt->nlookup,hash);
		if( f ) {
			if( f->field_index < 0 )
				break;
			s->t = obj->t;
			s->ft = f->t;
			s->offset = f->field_index;
			*ft = f->t;
			return (char*)obj + f->field_index;
		}
		rt = rt->parent;
	}

	s->t = obj->t;
	s->offset = -1;
	return NULL;
}

HL_PRIM vdynamic *HL_NAME(getp)( vdynamic *obj, int hash, int site ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL )
		return (vdynamic*)hl_dyn_getp(obj,hash,&hlt_dyn);
	return hl_is_ptr(ft) ? *(vdynamic**)addr : hl_make_dyn(addr,ft);
}

HL_PRIM int HL_NAME(geti)( vdynamic *obj, int hash, int site ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL )
		return hl_dyn_geti(obj,hash,&hlt_i32);
	switch( ft->kind ) {
	case HI32:
		return *(int*)addr;
	case HBOOL:
	case HUI8:
		return *(unsigned char*)addr;
	case HUI16:
		return *(unsigned short*)addr;
	default:
		return hl_dyn_casti(addr,ft,&hlt_i32);
	}
}

HL_PRIM double HL_NAME(getd)( vdynamic *obj, int hash, int site ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL )
		return hl_dyn_getd(obj,hash);
	return ft->kind == HF64 ? *(double*)addr : hl_dyn_castd(addr,ft);
}

HL_PRIM void HL_NAME(setp)( vdynamic *obj, int hash, int site, vdynamic *value ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL ) {
		hl_dyn_setp(obj,hash,&hlt_dyn,value);
		return;
	}
	if( hl_is_ptr(ft) && (value == NULL || hl_same_type(value->t,ft)) )
		*(void**)addr = value;
	else
		hl_write_dyn(addr,ft,value,false);
}

HL_PRIM void HL_NAME(seti)( vdynamic *obj, int hash, int site, int value ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL ) {
		hl_dyn_seti(obj,hash,&hlt_i32,value);
		return;
	}
	switch( ft->kind ) {
	case HI32:
		*(int*)addr = value;
		break;
	case HBOOL:
	case HUI8:
		*(unsigned char*)addr = (unsigned char)value;
		break;
	case HUI16:
		*(unsigned short*)addr = (unsigned short)value;
		break;
	default:
		hl_dyn_seti(obj,hash,&hlt_i32,value);
		break;
	}
}

HL_PRIM void HL_NAME(setd)( vdynamic *obj, int hash, int site, double value ) {
	hl_type *ft;
	void *addr = hxs_field(obj,hash,site,&ft);
	if( addr == NULL || ft->kind != HF64 ) {
		hl_dyn_setd(obj,hash,value);
		return;
	}
	*(double*)addr = value;
}

/**
	@param name The field name, as HashLink holds a string.
	@return What the VM hashes it to.

	Asked for rather than worked out again. The emitter has to write the same number the jit would
	have written for ODynGet, and a second implementation of a hash is a second thing to be wrong.
*/
HL_PRIM int HL_NAME(hash)( vbyte *name ) {
	return hl_hash_gen((uchar*)name,true);
}

static hxs_native hxs_native_table[] = {
	{ "getp", (void*)HL_NAME(getp) },
	{ "geti", (void*)HL_NAME(geti) },
	{ "getd", (void*)HL_NAME(getd) },
	{ "setp", (void*)HL_NAME(setp) },
	{ "seti", (void*)HL_NAME(seti) },
	{ "setd", (void*)HL_NAME(setd) },
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

	hxs_setup_snapshot();

	if( !hl_module_init(m, false) ) {
		hl_setup = hxs_setup_before;
		hl_module_free(m);
		hl_code_free(code);
		hxs_last_error = "could not link the module";
		return NULL;
	}

	/*
		Held before the hooks are reconciled, because the dispatcher decides what a function pointer
		belongs to by looking through what is held, and the host may make a dynamic call at any point
		after this returns.
	*/
	h = (hxs_module *)hl_gc_alloc_finalizer(sizeof(hxs_module));
	h->finalize = (void (*)(void *))hxs_module_finalize;
	h->m = m;
	h->code = code;
	hxs_hold(h);

	hxs_setup_reconcile();
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

/**
	@return Which fields of hl_setup loading has taken from the host so far, as bits.

	Every one of them has been given back or replaced by something that defers to the host's, so this
	is not a fault report. It is how a test notices that a hashlink this was not written against
	takes a hook nobody here has heard of, while that hook is still working because it was restored.
*/
HL_PRIM int HL_NAME(hooks)( void ) {
	return hxs_setup_taken;
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

/*
	No bytecode can be loaded here, so nothing will ever call a site's cache. The number is still
	handed out, because whatever asked for it is on the interpreted path and should not have to know
	which build it is in.
*/
HL_PRIM int HL_NAME(site)( void ) {
	return -1;
}

HL_PRIM int HL_NAME(hash)( vbyte *name ) {
	return hl_hash_gen((uchar*)name,true);
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

HL_PRIM int HL_NAME(hooks)( void ) {
	return 0;
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
DEFINE_PRIM(_I32, hooks, _NO_ARG);
DEFINE_PRIM(_I32, site, _NO_ARG);
DEFINE_PRIM(_I32, hash, _BYTES);
DEFINE_PRIM(_VOID, set_global, _ABSTRACT(hxs_module) _I32 _DYN);
DEFINE_PRIM(_ABSTRACT(hxs_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, entry_index, _ABSTRACT(hxs_module));
DEFINE_PRIM(_DYN, closure, _ABSTRACT(hxs_module) _I32);
