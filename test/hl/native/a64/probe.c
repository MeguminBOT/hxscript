/*
	Prints the case list, one way or the other.

	With no argument it prints what each encoder in a64.h returned, as one hex word per line with the
	mnemonic beside it. With `asm` it prints the mnemonics alone, which is a file an assembler reads.
	run.sh takes both and compares them, so the thing being checked and the thing checking it come
	from the same list and cannot fall out of step.

	This is built for whatever machine is running it, never for arm64. The encoder is arithmetic on
	integers and does not care where it runs, which is the whole reason it can be checked here.
*/
#include <stdio.h>
#include <string.h>

#include "a64.h"

int main( int argc, char **argv ) {
	int as_asm = argc > 1 && strcmp(argv[1], "asm") == 0;

#define A64_CASE(insn, text) \
	if( as_asm ) printf("%s\n", text); else printf("%08x\t%s\n", (unsigned int)(insn), text);
#include "cases.h"
#undef A64_CASE

	return 0;
}
