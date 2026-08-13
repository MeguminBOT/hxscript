#!/usr/bin/env python
"""Applies this repository's hxcpp fixes to whichever hxcpp a build actually links.

    python patches/apply-hxcpp.py            apply, and say what was already there
    python patches/apply-hxcpp.py --check    report only, change nothing
    python patches/apply-hxcpp.py --revert   put the originals back
    python patches/apply-hxcpp.py --path X   use the hxcpp at X rather than asking haxelib

Each fix is written out as literal before and after text rather than as a diff, because a diff needs
matching line endings and an hxcpp checkout on Windows may have either. Applying is idempotent: a
fix already present is reported and skipped, so this can be run after every `haxelib upgrade`.

Every fix is described in HXCPP-ISSUES.md, which is where the reasoning lives. The numbers here are
that file's numbers.

Nothing is written unless every fix that is not already applied matched exactly. A partial apply
would leave hxcpp in a state nobody has tested.
"""

import os
import re
import subprocess
import sys

# One entry per fix: the issue it closes, the file, and the text before and after.
FIXES = [
    {
        'issue': 1,
        'name': 'a member declared Bool gets fsBool storage',
        'file': 'src/hx/cppia/CppiaVars.cpp',
        'before': """      switch(exprType)
      {
         case etInt: ioOffset += sizeof(int); storeType=fsInt; break;
         case etFloat: ioOffset += sizeof(Float);storeType=fsFloat;  break;
         case etString: ioOffset += sizeof(String);storeType=fsString;  break;
         case etObject: ioOffset += sizeof(hx::Object *);storeType=fsObject;  break;
         case etVoid:
         case etNull:
            break;
      }""",
        'after': """      storeType = typeId==0 ? fsObject : fieldStorageFromType(type);

      switch(storeType)
      {
         case fsBool: ioOffset += sizeof(int); break;
         case fsByte: ioOffset += sizeof(int); break;
         case fsInt: ioOffset += sizeof(int); break;
         case fsFloat: ioOffset += sizeof(Float); break;
         case fsString: ioOffset += sizeof(String); break;
         case fsObject: ioOffset += sizeof(hx::Object *); break;
         case fsUnknown:
            break;
      }""",
    },
    {
        'issue': 2,
        'name': 'DataVal reports itself as a boolean to the JIT',
        'file': 'src/hx/cppia/Cppia.cpp',
        'before': """   const char *getName() HXCPP_OVERRIDE { return "DataVal"; }

   ExprType getType() HXCPP_OVERRIDE { return (ExprType)ExprTypeOf<T>::value; }""",
        'after': """   const char *getName() HXCPP_OVERRIDE { return "DataVal"; }

   bool isBoolInt() HXCPP_OVERRIDE { return ExprTypeIsBool<T>::value; }

   ExprType getType() HXCPP_OVERRIDE { return (ExprType)ExprTypeOf<T>::value; }""",
    },
    {
        'issue': 3,
        'name': 'convert moves registers with a width, so the JIT accepts them',
        'file': 'src/hx/cppia/CppiaCompiler.cpp',
        'before': """                     move(sJitArg0, inSrc);
                     add( sJitTemp1, inTarget.getReg(), inTarget.offset );
                     callNative( (void *)intToStr, sJitArg0.as(jtInt), sJitTemp1.as(jtPointer));""",
        'after': """                     move(sJitArg0.as(jtInt), inSrc.as(jtInt));
                     add( sJitTemp1, inTarget.getReg(), inTarget.offset );
                     callNative( (void *)intToStr, sJitArg0.as(jtInt), sJitTemp1.as(jtPointer));""",
    },
    {
        'issue': 3,
        'name': 'convert moves an object with a width, for objToStr',
        'file': 'src/hx/cppia/CppiaCompiler.cpp',
        'before': """                  move(sJitArg0, inSrc);
                  add( sJitTemp1, inTarget.getReg(), inTarget.offset );
                  callNative( (void *)objToStr, sJitArg0.as(jtPointer), sJitTemp1.as(jtPointer) );""",
        'after': """                  move(sJitArg0.as(jtPointer), inSrc.as(jtPointer));
                  add( sJitTemp1, inTarget.getReg(), inTarget.offset );
                  callNative( (void *)objToStr, sJitArg0.as(jtPointer), sJitTemp1.as(jtPointer) );""",
    },
    {
        'issue': 3,
        'name': 'convert moves an object with a width, for objToFloat',
        'file': 'src/hx/cppia/CppiaCompiler.cpp',
        'before': """                  move(sJitArg0, inSrc);
                  makeAddress(sJitTemp1,inTarget);
                  callNative( (void *)objToFloat, sJitArg0.as(jtPointer), sJitTemp1.as(jtPointer));""",
        'after': """                  move(sJitArg0.as(jtPointer), inSrc.as(jtPointer));
                  makeAddress(sJitTemp1,inTarget);
                  callNative( (void *)objToFloat, sJitArg0.as(jtPointer), sJitTemp1.as(jtPointer));""",
    },
]


def hxcpp_root(override):
    """Where hxcpp is, asked of haxelib unless it was given."""
    if override:
        return override

    try:
        out = subprocess.check_output(['haxelib', 'path', 'hxcpp'], stderr=subprocess.STDOUT)
    except Exception as e:
        sys.exit('could not run `haxelib path hxcpp`: %s\npass --path instead' % e)

    for line in out.decode('utf-8', 'replace').splitlines():
        line = line.strip()
        if line and not line.startswith('-') and os.path.isdir(line):
            return line

    sys.exit('`haxelib path hxcpp` named no directory; pass --path instead')


def read(path):
    """The file as text, with its newline style remembered so writing back keeps it."""
    with open(path, 'rb') as f:
        raw = f.read()

    newline = '\r\n' if b'\r\n' in raw else '\n'
    return raw.decode('utf-8', 'replace').replace('\r\n', '\n'), newline


def write(path, text, newline):
    with open(path, 'wb') as f:
        f.write(text.replace('\n', newline).encode('utf-8'))


def main():
    args = sys.argv[1:]
    check = '--check' in args
    revert = '--revert' in args

    override = None
    if '--path' in args:
        at = args.index('--path')
        if at + 1 >= len(args):
            sys.exit('--path wants a directory after it')
        override = args[at + 1]

    root = hxcpp_root(override)
    print('hxcpp: %s' % root)

    # Text per file as it is being built up. Several fixes touch one file, so each has to be applied
    # to the running text rather than to what was on disk: computing each from the original and
    # writing them in turn means the last write throws the others away.
    working = {}
    changed = []
    already = 0

    for fix in FIXES:
        path = os.path.join(root, fix['file'].replace('/', os.sep))
        label = 'issue %d, %s' % (fix['issue'], fix['name'])

        if not os.path.isfile(path):
            sys.exit('  MISSING  %s\n           no %s under that hxcpp' % (label, fix['file']))

        if path not in working:
            working[path] = read(path)

        text, newline = working[path]
        want, have = (fix['before'], fix['after']) if revert else (fix['after'], fix['before'])

        if want in text:
            print('  already  %s' % label)
            already += 1
            continue

        if have not in text:
            sys.exit('  NO MATCH %s\n           neither form is in %s. That hxcpp is a version this\n'
                     '           script has not been taught, and nothing has been written.'
                     % (label, fix['file']))

        if text.count(have) != 1:
            sys.exit('  AMBIGUOUS %s\n           %d places match in %s, expected one.'
                     % (label, text.count(have), fix['file']))

        working[path] = (text.replace(have, want, 1), newline)
        changed.append((path, label))

    if not changed:
        print('nothing to do: all %d already %s' % (already, 'reverted' if revert else 'applied'))
        return 0

    if check:
        for _, label in changed:
            print('  would %s %s' % ('revert' if revert else 'apply', label))
        return 1

    for path in sorted(set(path for path, _ in changed)):
        text, newline = working[path]
        write(path, text, newline)

    for _, label in changed:
        print('  %s %s' % ('reverted' if revert else 'applied ', label))

    print('\n%d changed, %d already there.' % (len(changed), already))
    print('hxcpp compiles its runtime into each project, so anything built before this keeps the old')
    print('behaviour until it is rebuilt.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
