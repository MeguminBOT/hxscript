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
	Every native is defined either way, which is what lets an HL/C program on any architecture link
	against this file unchanged; on one without the loader they answer that they cannot help, the
	library reports itself unusable, and every script is interpreted. That is the same answer, by the
	same path, that a HashLink host already gets when the extension is not there at all.

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

/*
	Loading emitted bytecode into a running HashLink process.

	HashLink's loader is compiled into hl.exe rather than libhl, so a host has no way to reach it.
	This extension carries hashlink's own code.c, module.c and jit.c and calls them, which keeps the
	VM stock: a host ships this .hdll beside the others and runs `hl game.hl` as before.

	Nothing here allocates: gc.c and allocator.c stay in libhl, so a module loaded through this one
	shares the host's heap and collector rather than getting its own.

	The same file is also what an HL/C program compiles in. There it is linked rather than loaded,
	and the header Haxe generates for its natives declares exactly the symbols defined below, so
	nothing about it changes between the two ways of shipping.
*/

/** Why the loader cannot be used, as `state` reports it. */
#define HXS_STATE_USABLE	0
#define HXS_STATE_NO_LOADER	1
#define HXS_STATE_DISAGREES	2

#ifdef HXS_LOADER

#include <hlmodule.h>

typedef struct {
	void (*finalize)(void *);
	hl_module *m;
	hl_code *code;
} hxs_module;

static void hxs_module_finalize(hxs_module *h) {
	if (h->m) {
		hl_module_free(h->m);
		h->m = NULL;
	}
	if (h->code) {
		hl_code_free(h->code);
		h->code = NULL;
	}
}

/*
	Whether this was built against the same hashlink the VM is running.

	The extension does not merely call libhl, it shares structures with it: the jit compiled in here
	emits machine code carrying literal byte offsets into objects libhl allocates. Those offsets come
	from the hl.h this was compiled against, and nothing checks that it was the same hl.h libhl was.
	The compiler only ever sees the headers it was handed, and the linker matches names rather than
	layouts, so a mismatched pair builds cleanly and then reads a field from the wrong place.

	libhl publishes no version to compare against, so the layouts are tested instead of trusted:
	values are put through libhl's own allocators and read back at the offsets this build believes
	in. Cheap, and it fails where the mistake is rather than somewhere unrelated later.
*/
static bool hxs_layouts_agree(void) {
	vclosure *c;
	varray *a;
	vdynamic *d;

	c = hl_alloc_closure_void(&hlt_dyn, (void *)&hlt_i32);
	if (c == NULL || c->t != &hlt_dyn || c->fun != (void *)&hlt_i32 || c->hasValue != 0)
		return false;

	a = hl_alloc_array(&hlt_i32, 3);
	if (a == NULL || a->at != &hlt_i32 || a->size != 3)
		return false;

	d = hl_alloc_dynamic(&hlt_i32);
	if (d == NULL || d->t != &hlt_i32)
		return false;

	d->v.i = 0x5A5A5A5A;
	if (hl_dyn_casti(&d, &hlt_dyn, &hlt_i32) != 0x5A5A5A5A)
		return false;

	return true;
}

/** The last failure's message, for a host that wants to report rather than guess. */
static char *hxs_last_error = NULL;

/**
	Reads, links and jits a module.

	@return An opaque handle, or NULL when it could not be read; `last_error` then says why.
*/
HL_PRIM hxs_module *HL_NAME(load)(vbyte *data, int size) {
	hl_code *code;
	hl_module *m;
	hxs_module *h;

	hxs_last_error = NULL;

	code = hl_code_read((const unsigned char *)data, size, &hxs_last_error);
	if (code == NULL)
		return NULL;

	m = hl_module_alloc(code);
	if (m == NULL) {
		hl_code_free(code);
		hxs_last_error = "could not allocate the module";
		return NULL;
	}

	if (!hl_module_init(m, false)) {
		hl_module_free(m);
		hl_code_free(code);
		hxs_last_error = "could not link the module";
		return NULL;
	}

	h = (hxs_module *)hl_gc_alloc_finalizer(sizeof(hxs_module));
	h->finalize = (void (*)(void *))hxs_module_finalize;
	h->m = m;
	h->code = code;
	return h;
}

/** @return The function index the module names as its entry point. */
HL_PRIM int HL_NAME(entry_index)(hxs_module *h) {
	return h == NULL ? -1 : h->code->entrypoint;
}

/**
	Wraps one of the module's functions as an ordinary Haxe function value.

	This is what lets a compiled script stand in for an interpreted one without the interpreter
	knowing: what comes back is a closure like any other.
*/
HL_PRIM vclosure *HL_NAME(closure)(hxs_module *h, int findex) {
	hl_type *t;
	void *fun;

	if (h == NULL || findex < 0 || findex >= h->code->nfunctions + h->code->nnatives)
		return NULL;

	t = h->code->functions[h->m->functions_indexes[findex]].type;
	fun = h->m->functions_ptrs[findex];
	if (fun == NULL)
		return NULL;

	return hl_alloc_closure_void(t, fun);
}

/**
	Puts a value in one of a loaded module's globals.

	This is how compiled code reaches the host: the emitter leaves a global for each host value a
	script names, and these are filled once after loading rather than looked up per call. Only a
	pointer-typed global may be written, which is every global the emitter makes, because
	hl_module_init roots exactly those and a value written anywhere else would be invisible to the
	collector.
*/
HL_PRIM void HL_NAME(set_global)(hxs_module *h, int index, vdynamic *value) {
	hl_type *t;

	if (h == NULL || index < 0 || index >= h->code->nglobals)
		return;

	t = h->code->globals[index];
	if (!hl_is_ptr(t))
		return;

	*(vdynamic **)(h->m->globals_data + h->m->globals_indexes[index]) = value;
}

/** @return Why the loader cannot be used, or HXS_STATE_USABLE when it can. */
HL_PRIM int HL_NAME(state)(void) {
	return hxs_layouts_agree() ? HXS_STATE_USABLE : HXS_STATE_DISAGREES;
}

HL_PRIM vbyte *HL_NAME(last_error)(void) {
	return (vbyte *)hxs_last_error;
}

#else

/*
	The same seven natives on an architecture hashlink cannot jit for.

	They exist so that the link is the same everywhere and a host has one thing to ask rather than
	two. What they answer is that there is no loader here, which the library already knows how to act
	on: `Loader.available` is false, `Compiler.available` is false, and scripts are interpreted.
*/

typedef struct {
	void (*finalize)(void *);
} hxs_module;

HL_PRIM hxs_module *HL_NAME(load)(vbyte *data, int size) {
	return NULL;
}

HL_PRIM int HL_NAME(entry_index)(hxs_module *h) {
	return -1;
}

HL_PRIM vclosure *HL_NAME(closure)(hxs_module *h, int findex) {
	return NULL;
}

HL_PRIM void HL_NAME(set_global)(hxs_module *h, int index, vdynamic *value) {
}

HL_PRIM int HL_NAME(state)(void) {
	return HXS_STATE_NO_LOADER;
}

HL_PRIM vbyte *HL_NAME(last_error)(void) {
	return (vbyte *)"this build carries no loader, because HashLink's jit is x86 and x86-64 only";
}

#endif

/** @return Whether the loader is here and agrees with the libhl it is running against. */
HL_PRIM bool HL_NAME(agrees)(void) {
	return HL_NAME(state)() == HXS_STATE_USABLE;
}

/** @return The hashlink this was built against, for a host that wants to say so in a report. */
HL_PRIM int HL_NAME(built_for)(void) {
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
