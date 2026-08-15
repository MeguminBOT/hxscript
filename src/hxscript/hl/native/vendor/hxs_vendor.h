/*
	Renames every symbol the vendored loader defines.

	HashLink's loader is compiled into hl.exe rather than into libhl, so a process that runs on the
	VM already holds a copy of all of this, and a process built as HL/C holds none of it. Carrying
	our own copy is what makes the two the same, and the risk that creates is that the two copies
	meet: on a platform whose dynamic linker exports the executable's symbols, a reference from this
	build can bind to the VM's definition instead of ours. That build links cleanly and then reads a
	structure one version of hashlink wrote with the other version's field offsets.

	Renaming removes the possibility rather than arguing about when it can happen. Nothing here is
	exported, nothing else in the process can reach these names, and the copy this build calls is
	always the copy this build compiled.

	Applied with -include on gcc and clang, /FI on MSVC, so the vendored sources stay byte for byte
	what hashlink released. A build that leaves the flag out still works, because none of these names
	exist in libhl; it just gives up the protection.

	The list is every symbol nm reports as defined and external across code.c, module.c and jit.c.
*/
#ifndef HXS_VENDOR_H
#define HXS_VENDOR_H

#define hl_code_read				hxs_code_read
#define hl_code_free				hxs_code_free
#define hl_code_hash_alloc			hxs_code_hash_alloc
#define hl_code_hash_finalize		hxs_code_hash_finalize
#define hl_code_hash_free			hxs_code_hash_free
#define hl_code_hash_remap_globals	hxs_code_hash_remap_globals
#define hl_code_hash_type			hxs_code_hash_type
#define hl_get_ustring				hxs_get_ustring
#define hl_op_name					hxs_op_name

#define hl_module_alloc				hxs_module_alloc
#define hl_module_init				hxs_module_init
#define hl_module_free				hxs_module_free
#define hl_module_patch				hxs_module_patch
#define hl_module_resolve_type		hxs_module_resolve_type
#define hl_module_capture_stack_range	hxs_module_capture_stack_range
#define hl_module_resolve_symbol_full	hxs_module_resolve_symbol_full

#define hl_jit_alloc				hxs_jit_alloc
#define hl_jit_free					hxs_jit_free
#define hl_jit_init					hxs_jit_init
#define hl_jit_reset				hxs_jit_reset
#define hl_jit_function				hxs_jit_function
#define hl_jit_code					hxs_jit_code
#define hl_jit_patch_method			hxs_jit_patch_method

#define write_unwind_data			hxs_write_unwind_data
#define write_uwcode				hxs_write_uwcode

#endif
