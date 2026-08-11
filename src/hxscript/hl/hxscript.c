#define HL_NAME(n) hxscript_##n
#include <hl.h>
#include <hlmodule.h>

/*
	Loading emitted bytecode into a running HashLink process.

	HashLink's loader is compiled into hl.exe rather than libhl, so a host has no way to reach it.
	This extension carries hashlink's own code.c, module.c and jit.c and calls them, which keeps the
	VM stock: a host ships this .hdll beside the others and runs `hl game.hl` as before.

	Nothing here allocates: gc.c and allocator.c stay in libhl, so a module loaded through this one
	shares the host's heap and collector rather than getting its own.
*/

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

/** The last failure's message, for a host that wants to report rather than guess. */
static char *hxs_last_error = NULL;

HL_PRIM vbyte *HL_NAME(last_error)(void) {
	return (vbyte *)hxs_last_error;
}

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

DEFINE_PRIM(_BYTES, last_error, _NO_ARG);
DEFINE_PRIM(_VOID, set_global, _ABSTRACT(hxs_module) _I32 _DYN);
DEFINE_PRIM(_ABSTRACT(hxs_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, entry_index, _ABSTRACT(hxs_module));
DEFINE_PRIM(_DYN, closure, _ABSTRACT(hxs_module) _I32);
