/**
	Asks the built module what it is, by loading it and calling into it.

	Reading a symbol table proves a name is present. This proves the thing behind the name answers,
	which on arm64 today is the whole of what it can honestly say: no loader, and here is the
	architecture that decided it. That pair is what a host reports when it explains why its scripts
	are interpreted, so it is worth checking rather than assuming.
*/
#include <dlfcn.h>
#include <stdio.h>

int main( int argc, char **argv ) {
	const char *path = argc > 1 ? argv[1] : "/tmp/hxscript.hdll";
	void *module = dlopen(path, RTLD_NOW);
	int (*state)( void );
	int (*arch)( void );

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
