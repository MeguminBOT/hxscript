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
	Whether this build carries the loader. HashLink's jit is x86 and x86-64 only, and this is decided
	before hl.h is included because hl.h defines the architecture macros back again.
*/
#if !defined(HXS_NO_JIT)
#	if defined(__x86_64__) || defined(__amd64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#		define HXS_LOADER
#	endif
#endif

#define HL_NAME(n) hxscript_##n
#include <hl.h>
#include <string.h>

/** The carried loader shares struct layouts with libhl, so a build against another hl.h interprets instead. */
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

/** A module this loaded, read and jitted. */
typedef struct {
	void (*finalize)(void *);
	hl_module *m;
	hl_code *code;
} hxs_module;

/** The last failure's message, for a host that wants to report rather than guess. */
static char *hxs_last_error = NULL;

/**
	Holds a loaded module for the life of the process, since a closure into jitted code has no
	reference back to it. Blocks never move, because hl_add_root records a slot's address.
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

/**
	Loading takes six fields of hl_setup that the host's own code is using, so the struct is copied
	before and restored after, and only the deliberate changes go back on top.
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

/** Restores the host's hl_setup, then reapplies only what this changes on purpose. */
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

/** Resolves lib `hxs` from this binary, which is the only way to reach it in an HL/C build. */
typedef struct {
	const char *name;
	void *fn;
} hxs_native;

/** One field access site: the name it reads, the last receiver type it saw, and where the field sat. */
typedef struct {
	hl_type *t;
	hl_type *ft;
	int offset;
	int hash;
	void *fptr;
} hxs_site;

/** What a site's offset says when it holds a method rather than a field. */
#define HXS_SITE_METHOD (-2)

static hxs_site *hxs_sites = NULL;
static int hxs_site_count = 0;
static int hxs_site_cap = 0;

/** @return A cache index for one access, baked into the bytecode as a constant, or -1. */
HL_PRIM int HL_NAME(site)( int hash ) {
	if( hxs_site_count == hxs_site_cap ) {
		int cap = hxs_site_cap ? hxs_site_cap * 2 : 256;
		hxs_site *grown = (hxs_site*)realloc(hxs_sites,sizeof(hxs_site) * cap);
		if( grown == NULL ) return -1;
		hxs_sites = grown;
		hxs_site_cap = cap;
	}
	memset(hxs_sites + hxs_site_count,0,sizeof(hxs_site));
	hxs_sites[hxs_site_count].hash = hash;
	return hxs_site_count++;
}

/** Whether instances of this type keep script fields the world reads for them, rather than HL fields. */
static bool hxs_is_scripted( hl_type *t ) {
	static int vars_hash = 0;
	hl_runtime_obj *rt;

	if( vars_hash == 0 )
		vars_hash = hl_hash_gen(USTR("__vars"),false);

	rt = hl_get_obj_rt(t);
	while( rt ) {
		if( hl_lookup_find(rt->lookup,rt->nlookup,vars_hash) )
			return true;
		rt = rt->parent;
	}
	return false;
}

/**
	Calls a static Haxe function of a known shape without going through hl_dyn_call.

	hl_dyn_call boxes every argument and reads the callee's signature to marshal against, and this
	path is taken on every access to a scripted instance, which is most of the accesses a script
	makes. A closure over no receiver is a plain function pointer with the platform's own convention,
	which is what both the jit and generated C produce, so it can be called as one.
*/
typedef vdynamic *(*hxs_read3)( vdynamic *, vdynamic *, vdynamic * );
typedef void (*hxs_write4)( vdynamic *, vdynamic *, vdynamic *, vdynamic * );
typedef void (*hxs_writei)( vdynamic *, vdynamic *, int, vdynamic * );
typedef void (*hxs_writed)( vdynamic *, vdynamic *, double, vdynamic * );
typedef int (*hxs_readi3)( vdynamic *, vdynamic *, vdynamic * );
typedef double (*hxs_readd3)( vdynamic *, vdynamic *, vdynamic * );

/** The world's own reader, writer and dispatchers, for what the fast path must not answer for. */
#define HXS_THROUGH_READ		0
#define HXS_THROUGH_WRITE		1
#define HXS_THROUGH_READ_INT	2
#define HXS_THROUGH_READ_FLOAT	3
#define HXS_THROUGH_CALL		4
#define HXS_THROUGH_WRITE_INT	8
#define HXS_THROUGH_WRITE_FLOAT	9
#define HXS_THROUGH_MEMBER		10
#define HXS_THROUGH_COUNT		12

static vclosure *hxs_through[HXS_THROUGH_COUNT] = { NULL };
static bool hxs_through_rooted = false;

/** Takes them in the order the library passes them, which the two sides agree on and nothing checks. */
HL_PRIM void HL_NAME(fallback)( varray *given ) {
	int i;
	int count = given == NULL ? 0 : given->size;

	if( count > HXS_THROUGH_COUNT )
		count = HXS_THROUGH_COUNT;

	for(i=0;i<count;i++)
		hxs_through[i] = hl_aptr(given,vclosure*)[i];

	if( !hxs_through_rooted ) {
		for(i=0;i<HXS_THROUGH_COUNT;i++)
			hl_add_root((void**)&hxs_through[i]);
		hxs_through_rooted = true;
	}
}

/**
	@return Where the field lives, or NULL when this receiver has no plain field of that name.

	A scripted instance is refused whatever it appears to have, because a script may declare a field
	that shadows one of its native base's and the world answers with the script's.
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

	if( obj->t->kind != HOBJ || hxs_is_scripted(obj->t) ) {
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

/** @return What the VM hashes a field name to, which an access has to carry. */
HL_PRIM int HL_NAME(hash)( vbyte *name ) {
	return hl_hash_gen((uchar*)name,true);
}

/**
	Reads a field for compiled code, falling through to the world's reader.

	@param slot The Haxe side cache the reader keeps for this same access.
	@param site This access's cache here.
*/
HL_PRIM vdynamic *HL_NAME(fetch)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr;
	vdynamic *args[3];

	addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	if( addr )
		return hl_is_ptr(ft) ? *(vdynamic**)addr : hl_make_dyn(addr,ft);

	if( hxs_through[HXS_THROUGH_READ] == NULL )
		return NULL;

	if( !hxs_through[HXS_THROUGH_READ]->hasValue )
		return ((hxs_read3)hxs_through[HXS_THROUGH_READ]->fun)(obj,name,slot);

	args[0] = obj;
	args[1] = name;
	args[2] = slot;
	return hl_dyn_call(hxs_through[HXS_THROUGH_READ],args,3);
}

/** Writes a field for compiled code, falling through to the world's writer. */
HL_PRIM void HL_NAME(store)( vdynamic *obj, vdynamic *name, vdynamic *value, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr;
	vdynamic *args[4];

	addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	if( addr ) {
		if( hl_is_ptr(ft) && (value == NULL || hl_same_type(value->t,ft)) )
			*(void**)addr = value;
		else
			hl_write_dyn(addr,ft,value,false);
		return;
	}

	if( hxs_through[HXS_THROUGH_WRITE] == NULL )
		return;

	if( !hxs_through[HXS_THROUGH_WRITE]->hasValue ) {
		((hxs_write4)hxs_through[HXS_THROUGH_WRITE]->fun)(obj,name,value,slot);
		return;
	}

	args[0] = obj;
	args[1] = name;
	args[2] = value;
	args[3] = slot;
	hl_dyn_call(hxs_through[HXS_THROUGH_WRITE],args,4);
}

/**
	Reads a field a compiled function wants as an Int, without boxing what it found.

	The slow path goes through the world's reader and then its own Int conversion, because a value a
	script holds may be a boxed abstract, which a cast cannot open and the conversion can.
*/
HL_PRIM int HL_NAME(fetchi)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr;
	vdynamic *args[3];
	vdynamic *answer;

	addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	if( addr ) {
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

	if( hxs_through[HXS_THROUGH_READ_INT] == NULL )
		return 0;

	if( !hxs_through[HXS_THROUGH_READ_INT]->hasValue )
		return ((hxs_readi3)hxs_through[HXS_THROUGH_READ_INT]->fun)(obj,name,slot);

	args[0] = obj;
	args[1] = name;
	args[2] = slot;
	answer = hl_dyn_call(hxs_through[HXS_THROUGH_READ_INT],args,3);
	return answer == NULL ? 0 : hl_dyn_casti(&answer,&hlt_dyn,&hlt_i32);
}

/** Reads a field a compiled function wants as a Float, without boxing what it found. */
HL_PRIM double HL_NAME(fetchd)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr;
	vdynamic *args[3];
	vdynamic *answer;

	addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	if( addr )
		return ft->kind == HF64 ? *(double*)addr : hl_dyn_castd(addr,ft);

	if( hxs_through[HXS_THROUGH_READ_FLOAT] == NULL )
		return 0.;

	if( !hxs_through[HXS_THROUGH_READ_FLOAT]->hasValue )
		return ((hxs_readd3)hxs_through[HXS_THROUGH_READ_FLOAT]->fun)(obj,name,slot);

	args[0] = obj;
	args[1] = name;
	args[2] = slot;
	answer = hl_dyn_call(hxs_through[HXS_THROUGH_READ_FLOAT],args,3);
	return answer == NULL ? 0. : hl_dyn_castd(&answer,&hlt_dyn);
}

/**
	Resolves a method on the receiver and remembers it, the way a field site remembers an offset.

	The convention is hashlink's own, from hl_dyn_call_obj: a negative field index names a method, the
	pointer is in the receiver's own runtime object, and the type carries the receiver as its first
	argument.

	@return Whether this receiver has a method of that name to call.
*/
static bool hxs_method( vdynamic *obj, int site, vclosure *out ) {
	hxs_site *s;
	hl_runtime_obj *rt;

	if( obj == NULL || site < 0 || site >= hxs_site_count )
		return false;

	s = hxs_sites + site;

	if( s->t == obj->t ) {
		if( s->offset != HXS_SITE_METHOD )
			return false;
		out->t = s->ft;
		out->fun = s->fptr;
		out->hasValue = 0;
#		ifdef HL_64
		out->stackCount = 0;
#		endif
		return true;
	}

	if( obj->t->kind != HOBJ || hxs_is_scripted(obj->t) ) {
		s->t = obj->t;
		s->offset = -1;
		return false;
	}

	rt = hl_get_obj_rt(obj->t);
	{
		hl_runtime_obj *at = rt;
		while( at ) {
			hl_field_lookup *f = hl_lookup_find(at->lookup,at->nlookup,s->hash);
			if( f ) {
				if( f->field_index >= 0 || f->t->kind != HFUN )
					break;
				s->t = obj->t;
				s->ft = f->t;
				s->fptr = rt->methods[-f->field_index - 1];
				s->offset = HXS_SITE_METHOD;
				out->t = f->t;
				out->fun = s->fptr;
				out->hasValue = 0;
#				ifdef HL_64
				out->stackCount = 0;
#				endif
				return true;
			}
			at = at->parent;
		}
	}

	s->t = obj->t;
	s->offset = -1;
	return false;
}

/** Calls the world's own dispatcher, for a receiver the fast path must not answer for. */
static vdynamic *hxs_dispatch( vdynamic *obj, vdynamic *name, vdynamic *slot, vdynamic **args, int nargs ) {
	vclosure *c = hxs_through[HXS_THROUGH_CALL + nargs];
	vdynamic *passed[8];
	int i;

	if( c == NULL )
		return NULL;

	if( !c->hasValue ) {
		switch( nargs ) {
		case 0:
			return ((hxs_read3)c->fun)(obj,name,slot);
		case 1:
			return ((vdynamic *(*)( vdynamic *, vdynamic *, vdynamic *, vdynamic * ))c->fun)(obj,name,slot,args[0]);
		case 2:
			return ((vdynamic *(*)( vdynamic *, vdynamic *, vdynamic *, vdynamic *, vdynamic * ))c->fun)(obj,name,slot,args[0],args[1]);
		default:
			return ((vdynamic *(*)( vdynamic *, vdynamic *, vdynamic *, vdynamic *, vdynamic *, vdynamic * ))c->fun)(obj,name,slot,args[0],args[1],args[2]);
		}
	}

	passed[0] = obj;
	passed[1] = name;
	passed[2] = slot;
	for(i=0;i<nargs;i++)
		passed[i + 3] = args[i];

	return hl_dyn_call(c,passed,nargs + 3);
}

/** Calls a method on a receiver whose type the site remembers, with the receiver passed first. */
static vdynamic *hxs_called( vdynamic *obj, vdynamic *name, vdynamic *slot, int site, vdynamic **args, int nargs ) {
	vclosure cl;
	vdynamic *passed[8];
	int i;
	int want;

	if( !hxs_method(obj,site,&cl) ) {
		/*
			A receiver of the world's own making keeps its methods as function values, so what is
			wanted is the value rather than a dispatch: the arguments are already here, and gathering
			them into an array for somebody else to take apart is an allocation per call.
		*/
		vclosure *ask = hxs_through[HXS_THROUGH_MEMBER];

		if( ask && !ask->hasValue ) {
			vclosure *fn = ((vclosure *(*)( vdynamic *, vdynamic *, vdynamic * ))ask->fun)(obj,name,slot);

			/*
				Only when the call passes exactly what the function declares. An optional argument
				left out is fewer, and filling one in is the world's business rather than this one's.
			*/
			if( fn && fn->t->kind == HFUN && fn->t->fun->nargs == nargs )
				return hl_dyn_call(fn,args,nargs);
		}

		return hxs_dispatch(obj,name,slot,args,nargs);
	}

	/*
		A method may declare more arguments than the call passes, which is what an optional argument
		is, and hl_dyn_call wants every one of them. Padding is only right where the argument can hold
		nothing; anything else goes to the world, which knows what a missing argument means there.
	*/
	want = cl.t->fun->nargs;
	if( want > (int)(sizeof(passed) / sizeof(passed[0])) || want < nargs + 1 )
		return hxs_dispatch(obj,name,slot,args,nargs);

	passed[0] = obj;
	for(i=0;i<nargs;i++)
		passed[i + 1] = args[i];

	for(i=nargs+1;i<want;i++) {
		if( !hl_is_ptr(cl.t->fun->args[i]) )
			return hxs_dispatch(obj,name,slot,args,nargs);
		passed[i] = NULL;
	}

	return hl_dyn_call(&cl,passed,want);
}

HL_PRIM vdynamic *HL_NAME(invoke0)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site ) {
	return hxs_called(obj,name,slot,site,NULL,0);
}

HL_PRIM vdynamic *HL_NAME(invoke1)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site, vdynamic *a ) {
	vdynamic *args[1];
	args[0] = a;
	return hxs_called(obj,name,slot,site,args,1);
}

HL_PRIM vdynamic *HL_NAME(invoke2)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site, vdynamic *a, vdynamic *b ) {
	vdynamic *args[2];
	args[0] = a;
	args[1] = b;
	return hxs_called(obj,name,slot,site,args,2);
}

HL_PRIM vdynamic *HL_NAME(invoke3)( vdynamic *obj, vdynamic *name, vdynamic *slot, int site, vdynamic *a, vdynamic *b, vdynamic *c ) {
	vdynamic *args[3];
	args[0] = a;
	args[1] = b;
	args[2] = c;
	return hxs_called(obj,name,slot,site,args,3);
}

/**
	Writes a number into a field without boxing it on the way in.

	A field of the host is written where it sits, the way the untyped writer does it. Anything else is
	the world's, and the world is handed the number rather than a box around it, which is the whole
	point of the typed pair.
*/
HL_PRIM void HL_NAME(storei)( vdynamic *obj, vdynamic *name, int value, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	vclosure *c;

	if( addr ) {
		switch( ft->kind ) {
		case HI32:
			*(int*)addr = value;
			return;
		case HBOOL:
		case HUI8:
			*(unsigned char*)addr = (unsigned char)value;
			return;
		case HUI16:
			*(unsigned short*)addr = (unsigned short)value;
			return;
		case HF64:
			*(double*)addr = value;
			return;
		default:
			hl_dyn_seti(obj,hxs_sites[site].hash,&hlt_i32,value);
			return;
		}
	}

	c = hxs_through[HXS_THROUGH_WRITE_INT];
	if( c == NULL || c->hasValue )
		return;

	((hxs_writei)c->fun)(obj,name,value,slot);
}

HL_PRIM void HL_NAME(stored)( vdynamic *obj, vdynamic *name, double value, vdynamic *slot, int site ) {
	hl_type *ft;
	void *addr = hxs_field(obj,site < 0 || site >= hxs_site_count ? 0 : hxs_sites[site].hash,site,&ft);
	vclosure *c;

	if( addr ) {
		if( ft->kind == HF64 ) {
			*(double*)addr = value;
			return;
		}
		hl_dyn_setd(obj,hxs_sites[site].hash,value);
		return;
	}

	c = hxs_through[HXS_THROUGH_WRITE_FLOAT];
	if( c == NULL || c->hasValue )
		return;

	((hxs_writed)c->fun)(obj,name,value,slot);
}

static hxs_native hxs_native_table[] = {
	{ "storei", (void*)HL_NAME(storei) },
	{ "stored", (void*)HL_NAME(stored) },
	{ "invoke0", (void*)HL_NAME(invoke0) },
	{ "invoke1", (void*)HL_NAME(invoke1) },
	{ "invoke2", (void*)HL_NAME(invoke2) },
	{ "invoke3", (void*)HL_NAME(invoke3) },
	{ "fetchi", (void*)HL_NAME(fetchi) },
	{ "fetchd", (void*)HL_NAME(fetchd) },
	{ "fetch", (void*)HL_NAME(fetch) },
	{ "store", (void*)HL_NAME(store) },
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

/** @return Whether libhl lays its structures out where this build believes they are. */
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
	Points classes a module declares at bases the world already has.

	Done between reading and linking, and it has to be: the jit reads a field's offset and a method's
	table position out of the runtime object libhl builds from the whole chain, and a class whose base
	arrives after that has every one of them wrong.

	The base is the host's own hl_type, never a copy of it. Sharing the hl_type_obj instead would put
	the host's class in this module's table, and hl_module_init writes a module context into every
	entry there.
*/
static void hxs_link_bases( hl_code *code, varray *at, varray *bases ) {
	int i, n;

	if( at == NULL || bases == NULL )
		return;

	n = at->size < bases->size ? at->size : bases->size;

	for(i=0;i<n;i++) {
		int index = hl_aptr(at,int)[i];
		hl_type *base = hl_aptr(bases,hl_type*)[i];

		if( index < 0 || index >= code->ntypes || base == NULL )
			continue;
		if( code->types[index].kind != HOBJ || base->kind != HOBJ )
			continue;

		code->types[index].obj->super = base;
	}
}

/** @return One of a loaded module's types, which is how the world makes a class value for it. */
HL_PRIM hl_type *HL_NAME(type_of)( hxs_module *h, int index ) {
	if( h == NULL || index < 0 || index >= h->code->ntypes )
		return NULL;

	return h->code->types + index;
}

/** @return How many entries a class's method table holds, which is where a method it does not have goes. */
HL_PRIM int HL_NAME(proto_count)( hl_type *t ) {
	if( t == NULL || t->kind != HOBJ )
		return -1;

	return hl_get_obj_rt(t)->nproto;
}

/** @return How many fields a class has, counting the ones it inherits, which is where a new one goes. */
HL_PRIM int HL_NAME(field_count)( hl_type *t ) {
	if( t == NULL || t->kind != HOBJ )
		return -1;

	return hl_get_obj_rt(t)->nfields;
}

/** @return Where a class keeps a method in its table, or -1 when nothing up its chain declares one. */
HL_PRIM int HL_NAME(proto_index)( hl_type *t, vbyte *name ) {
	hl_type_obj *o;
	int hash;

	if( t == NULL || t->kind != HOBJ )
		return -1;

	hash = hl_hash_gen((uchar*)name,true);

	for(o = t->obj; o; o = o->super ? o->super->obj : NULL) {
		int i;
		for(i=0;i<o->nproto;i++)
			if( o->proto[i].hashed_name == hash )
				return o->proto[i].pindex;
	}

	return -1;
}

/**
	@return What shape a class keeps a method in, as [nargs, return, each argument] by type kind, or
	NULL when nothing up its chain declares one.

	A script overriding a host method has to be written with the shape the host's own callers use,
	because taking that class's place in the method table means those callers reach it directly. The
	receiver counts as the first argument, the way it does everywhere else here.
*/
HL_PRIM varray *HL_NAME(proto_shape)( hl_type *base, vbyte *name ) {
	hl_runtime_obj *rt;
	int hash, i;

	if( base == NULL || base->kind != HOBJ )
		return NULL;

	hash = hl_hash_gen((uchar*)name,true);

	for(rt = hl_get_obj_rt(base); rt; rt = rt->parent) {
		hl_field_lookup *f = hl_lookup_find(rt->lookup,rt->nlookup,hash);
		varray *out;
		int *at;

		if( f == NULL || f->field_index >= 0 || f->t == NULL || f->t->kind != HFUN )
			continue;

		out = hl_alloc_array(&hlt_i32, f->t->fun->nargs + 2);
		at = hl_aptr(out,int);

		at[0] = f->t->fun->nargs;
		at[1] = f->t->fun->ret->kind;

		for(i=0;i<f->t->fun->nargs;i++)
			at[i + 2] = f->t->fun->args[i]->kind;

		return out;
	}

	return NULL;
}

/**
	@return A base's own version of a method, bound to an instance, or NULL when it has none.

	What `super.method()` means: the class the script extends answers, not whatever the instance's own
	table now points at, which is the script's override and would call itself forever.
*/
HL_PRIM vdynamic *HL_NAME(super_method)( hl_type *base, vdynamic *obj, vbyte *name ) {
	hl_runtime_obj *all, *rt;
	int hash;

	if( base == NULL || base->kind != HOBJ || obj == NULL )
		return NULL;

	hash = hl_hash_gen((uchar*)name,true);
	all = hl_get_obj_proto(base);

	for(rt = all; rt; rt = rt->parent) {
		hl_field_lookup *f = hl_lookup_find(rt->lookup,rt->nlookup,hash);

		if( f && f->field_index < 0 ) {
			void *fptr = all->methods[-f->field_index-1];
			return fptr == NULL ? NULL : (vdynamic*)hl_alloc_closure_ptr(f->t, fptr, obj);
		}
	}

	return NULL;
}

/** @return Whether a class up the chain declares a field of that name, which a script may not shadow. */
HL_PRIM bool HL_NAME(has_field)( hl_type *t, vbyte *name ) {
	hl_runtime_obj *rt;
	int hash;

	if( t == NULL || t->kind != HOBJ )
		return false;

	hash = hl_hash_gen((uchar*)name,true);

	for(rt = hl_get_obj_rt(t); rt; rt = rt->parent)
		if( hl_lookup_find(rt->lookup,rt->nlookup,hash) )
			return true;

	return false;
}

/** @return A handle on the read, linked and jitted module, or NULL; `last_error` says why. */
HL_PRIM hxs_module *HL_NAME(load)( vbyte *data, int size, varray *at, varray *bases ) {
	hl_code *code;
	hl_module *m;
	hxs_module *h;

	hxs_last_error = NULL;

	code = hl_code_read((const unsigned char *)data, size, &hxs_last_error);
	if( code == NULL )
		return NULL;

	hxs_link_bases(code, at, bases);

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

/** @return One of the module's functions as an ordinary closure, or null when there is no such function. */
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

/** Fills one of a module's globals, which is how compiled code reaches a host value. Pointers only, since hl_module_init roots exactly those. */
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

/** @return Which hl_setup fields loading has taken, as bits, all of them already given back. */
HL_PRIM int HL_NAME(hooks)( void ) {
	return hxs_setup_taken;
}

#else

/** The same natives where there is no loader, so the link is the same on every architecture. */

typedef struct {
	void (*finalize)(void *);
} hxs_module;

HL_PRIM hxs_module *HL_NAME(load)( vbyte *data, int size, varray *at, varray *bases ) {
	return NULL;
}

HL_PRIM hl_type *HL_NAME(type_of)( hxs_module *h, int index ) {
	return NULL;
}

HL_PRIM int HL_NAME(proto_count)( hl_type *t ) {
	return -1;
}

HL_PRIM int HL_NAME(field_count)( hl_type *t ) {
	return -1;
}

HL_PRIM int HL_NAME(proto_index)( hl_type *t, vbyte *name ) {
	return -1;
}

HL_PRIM bool HL_NAME(has_field)( hl_type *t, vbyte *name ) {
	return false;
}

HL_PRIM vdynamic *HL_NAME(super_method)( hl_type *base, vdynamic *obj, vbyte *name ) {
	return NULL;
}

HL_PRIM varray *HL_NAME(proto_shape)( hl_type *base, vbyte *name ) {
	return NULL;
}

/** No bytecode can be loaded here, so no cache is ever read. */
HL_PRIM int HL_NAME(site)( int hash ) {
	return -1;
}

HL_PRIM void HL_NAME(fallback)( varray *given ) {
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
DEFINE_PRIM(_I32, site, _I32);
DEFINE_PRIM(_VOID, fallback, _ARR);
DEFINE_PRIM(_I32, hash, _BYTES);
DEFINE_PRIM(_VOID, set_global, _ABSTRACT(hxs_module) _I32 _DYN);
DEFINE_PRIM(_ABSTRACT(hxs_module), load, _BYTES _I32 _ARR _ARR);
DEFINE_PRIM(_TYPE, type_of, _ABSTRACT(hxs_module) _I32);
DEFINE_PRIM(_I32, proto_count, _TYPE);
DEFINE_PRIM(_I32, field_count, _TYPE);
DEFINE_PRIM(_I32, proto_index, _TYPE _BYTES);
DEFINE_PRIM(_BOOL, has_field, _TYPE _BYTES);
DEFINE_PRIM(_DYN, super_method, _TYPE _DYN _BYTES);
DEFINE_PRIM(_ARR, proto_shape, _TYPE _BYTES);
DEFINE_PRIM(_I32, entry_index, _ABSTRACT(hxs_module));
DEFINE_PRIM(_DYN, closure, _ABSTRACT(hxs_module) _I32);
