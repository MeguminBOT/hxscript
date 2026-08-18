/**
	Asks the built module what it is, by loading it and calling into it.

	Reading a symbol table proves a name is present. This proves the thing behind the name answers,
	which on arm64 today is the whole of what it can honestly say: no loader, and here is the
	architecture that decided it. That pair is what a host reports when it explains why its scripts
	are interpreted, so it is worth checking rather than assuming.
*/
#include <dlfcn.h>
#include <stdio.h>

#include <hl.h>

int main( int argc, char **argv ) {
	const char *path = argc > 1 ? argv[1] : "/tmp/hxscript.hdll";
	void *module;
	int (*state)( void );
	int (*arch)( void );
	int stack_top = 0;

	/**
		Asking a module whether it agrees with the VM makes it allocate a closure, an array and a
		dynamic and compare what came back against what it expects, so the collector has to be running
		before the question is put. A host has done this long before it asks; a program written only to
		ask has to be told.
	*/
	hl_global_init();
	hl_register_thread(&stack_top);

	module = dlopen(path, RTLD_NOW);

	if( module == NULL ) {
		printf("it did not load: %s\n", dlerror());
		return 1;
	}

	state = (int (*)( void ))dlsym(module, "hxscript_state");
	arch = (int (*)( void ))dlsym(module, "hxscript_arch");

	if( state == NULL || arch == NULL ) {
		printf("it loaded, and state or arch is not in it\n");
		return 1;
	}

	printf("%d %d\n", state(), arch());
	return 0;
}
