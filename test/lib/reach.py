#!/usr/bin/env python
"""Writes docs/verified-imports.md: what a script can import and use, per game library.

    python test/lib/reach.py                                 both shipped stacks
    python test/lib/reach.py flixel flixel-addons flixel-ui   just that one

Nothing here is read off `Presets`, because a record and a build can disagree and only one of them is
what a script gets. Two things are run and their answers recorded.

The wiring macro, for what the build set out to do: which records were live, which bases got a
bridge, which abstracts were asked to be wrapped. That comes from its own `-D hxscript_verbose`
output.

`Probe.hx`, for what a script actually gets: it writes an `import` for every type in the build, runs
it, and reports whether the name came back with a runtime form behind it. This is the part a
filesystem walk cannot do. A type dead code elimination dropped, an abstract whose wrapper was never
generated and a typedef of a shape the interpreter cannot represent all accept the `import` line and
then answer nothing, so they read as present right up until a script uses one.

Library versions are asked of `haxelib path`, so this runs wherever the libraries are installed.

The probe runs on the targets a game ships as, hxcpp first and HL/C second, rather than on eval. That
costs a real build per stack and is the only way the answer means anything: dead code elimination is
what strips a member, and it is a property of the target. HL/C needs a HashLink installation for
`hl.h` and `libhl`, which `src/hxscript/hl/native/build.sh` finds under `/c/hashlink/*` or takes from
`HLPATH`. A stack neither target can build is reported as not verified, with both build errors,
rather than guessed at.

What it still cannot tell you is the member half. A type being usable is not every member on it being
reachable: under the default `-dce std` a member no compiled call site touches is stripped, and an
`inline` member has no runtime form at any setting.
"""

import collections
import glob
import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'docs', 'verified-imports.md')


def run(args):
    return subprocess.run(args, capture_output=True, text=True, cwd=ROOT).stdout


def versions(libs):
    out = {}
    for lib in libs:
        for line in run(['haxelib', 'path', lib]).splitlines():
            m = re.match(r'-D\s+([\w-]+)=([\w.]+)', line.strip())
            if m:
                out[m.group(1)] = m.group(2)
    return out


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def balanced(text, start):
    depth = 0
    for j in range(start, len(text)):
        if text[j] in '{[':
            depth += 1
        elif text[j] in '}]':
            depth -= 1
            if depth == 0:
                return text[start:j + 1]
    return ''


def presets():
    src = io.open(os.path.join(ROOT, 'src', 'hxscript', 'setup', 'Presets.hx'), encoding='utf-8').read()
    out = {}
    for m in re.finditer(r'public static final (\w+):Library = \{', src):
        body = balanced(src, m.end() - 1)
        rec = {}
        for f in ('roots', 'ignore', 'types', 'bases', 'abstracts', 'globals'):
            fm = re.search(r'\b' + f + r':\s*\[', body)
            rec[f] = re.findall(r"'([^']+)'", strip_comments(balanced(body, fm.end() - 1))) if fm else []
        rec['define'] = (re.search(r"define:\s*'([^']+)'", body) or [None, '?'])[1]
        rec['title'] = (re.search(r"title:\s*'([^']+)'", body) or [None, '?'])[1]
        # `requires` may name several defines, all of which must hold. The first is the library; the
        # rest are the platform it is compilable on, which `haxelib path` knows nothing about.
        req = re.search(r"requires:\s*'([^']+)'", body)
        rec['haxelib'] = req.group(1).split(',')[0].strip() if req else rec['define']
        out[m.group(1)] = rec
    return out


def wire(libs):
    """Run the wiring macro and read what it reported."""
    probe = os.path.join(ROOT, 'bin_reach')
    os.makedirs(probe, exist_ok=True)
    main = os.path.join(probe, 'ReachMain.hx')
    io.open(main, 'w', encoding='utf-8').write('class ReachMain { static function main() {} }\n')

    args = ['haxe', '-cp', 'src', '-cp', probe, '-D', 'hxscript', '-D', 'hxscript_verbose']
    for lib in libs:
        args += ['-lib', lib]

    if 'flixel' in libs:
        args += ['--macro', 'flixel.system.macros.FlxDefines.run()']

    # What lime's tools apply and a bare `haxe` does not. Without it `flash.geom.Rectangle` in
    # haxeui-flixel's `FlxStyleHelper` resolves to Haxe's own flash extern, whose `setTo` is
    # `@:require(flash11)`, a feature no target but flash has. The real build never sees this, so
    # without the remap the only error here is one the doc's own measurement disproves.
    if 'openfl' in libs or 'flixel' in libs:
        args += ['--remap', 'flash:openfl']

    # Typed against cpp and generating nothing. This used to say `-js`, which is quick and is a target
    # a game library may refuse outright: hxvlc's own check macro ends the build with `The current
    # target platform isn't supported` unless `cpp`, `desktop` or `mobile` is defined. `--no-output`
    # keeps it to typing, which is all this pass reads, and cpp is a target every shipped stack types
    # on even where it cannot finish a build.
    args += ['-main', 'ReachMain', '--macro', 'hxscript.setup.Autowire.run()',
             '-cpp', os.path.join(probe, 'wire'), '--no-output']
    p = subprocess.run(args, capture_output=True, text=True, cwd=ROOT)
    text = p.stdout + p.stderr

    wired = re.search(r'wiring ([^\n]+)', text)
    return {
        'wired': [w.strip().rstrip('.') for w in wired.group(1).split(',')] if wired else [],
        'abstracts': sorted(set(re.findall(r'^\(unknown\) :     ([a-z][\w.]*\.[A-Z]\w*)\s*$', text, re.M))),
        'bridges': sorted(re.findall(r'hxscript\.wired\.(\w+) extends ([\w.]+)', text), key=lambda x: x[1]),
        'notBridged': re.findall(r'not bridged: ([^\n]+)', text),
        'skipped': sorted(set(re.findall(r'(Skipping \w+ of \w+: [^\n]+)', text))),
        'ok': 'reach' in text,
    }


def unix_shell():
    """A POSIX shell for `build.sh`.

    Derived from git rather than looked up by name. On Windows `bash` on PATH is usually WSL's, which
    is a different filesystem: handed a Windows path it reports the script missing. Git for Windows
    ships the shell that shares this filesystem, and `git --exec-path` locates it without hard-coding
    an install directory.
    """
    if os.name != 'nt':
        return shutil.which('sh') or shutil.which('bash')

    where = subprocess.run(['git', '--exec-path'], capture_output=True, text=True).stdout.strip()
    if where:
        exe = os.path.abspath(os.path.join(where, '..', '..', '..', 'bin', 'bash.exe'))
        if os.path.isfile(exe):
            return exe
    return shutil.which('bash')


def hashlink_root():
    """The HashLink installation, found the way `build.sh` finds it so the two never disagree."""
    root = os.environ.get('HLPATH')
    if root and os.path.isdir(root):
        return root

    for guess in glob.glob('/c/hashlink/*') + glob.glob('C:/hashlink/*') + \
            ['/usr/local', '/usr', '/opt/hashlink', os.path.expanduser('~/hashlink')]:
        if os.path.isfile(os.path.join(guess, 'include', 'hl.h')) or \
                os.path.isfile(os.path.join(guess, 'hl.h')):
            return guess
    return None


def carry_runtime(root, beside):
    """Copies HashLink's shared libraries next to an HL/C binary.

    An HL/C program links the loader in and still loads `libhl` and the native bindings dynamically,
    so a binary on its own exits `0xC0000135` before running a line. `apps/sandbox-heaps/export/hlc`
    keeps the same set beside its executable for the same reason.
    """
    if not root:
        return

    for pattern in ('*.dll', '*.hdll', '*.so', '*.dylib'):
        for f in glob.glob(os.path.join(root, pattern)):
            try:
                shutil.copy2(f, beside)
            except OSError:
                pass


def binary(*parts):
    path = os.path.join(ROOT, 'bin_reach', *parts)
    return path + '.exe' if os.name == 'nt' else path


TOP_TOC = '<!--TOC-->'
STACK_TOC = '<!--STACK-TOC-->'


def slug(text, seen):
    """GitHub's anchor for a heading, deduped the way GitHub dedupes.

    Every stack repeats the same four subheadings, so `### Not usable` exists once per stack and a
    naive `#not-usable` would send both entries to the first one. GitHub resolves that by suffixing
    repeats in document order, which only works if the anchors are worked out over the finished
    document rather than as each section is written.
    """
    s = re.sub(r'[^\w\- ]', '', text.strip().lower()).replace(' ', '-')
    n = seen[s]
    seen[s] += 1
    return s if n == 0 else '%s-%d' % (s, n)


def contents(lines):
    """Fills in the placeholders with links to the headings that follow them."""
    seen = collections.Counter()
    heads = []

    for i, line in enumerate(lines):
        m = re.match(r'^(##+) (.+)$', line)
        if m:
            heads.append((i, len(m.group(1)), m.group(2), slug(m.group(2), seen)))

    out = list(lines)

    for i, line in enumerate(lines):
        if line == TOP_TOC:
            # Everything at the top level except the contents themselves, which nobody navigates to.
            out[i] = '\n'.join('- [%s](#%s)' % (t, a)
                               for _j, d, t, a in heads if d == 2 and t != 'Contents')
        elif line == STACK_TOC:
            # The subheadings between this stack's heading and the next one at the same level.
            under = []
            for j, d, t, a in heads:
                if j < i:
                    continue
                if d == 2:
                    break
                under.append('- [%s](#%s)' % (t, a))
            out[i] = '\n'.join(under)

    return [l for l in out if l not in (TOP_TOC, STACK_TOC)]


# Namespaces a library shares with the standard library, where the first segment does not identify
# whose types they are.
SHARED = ('haxe', 'sys', 'cpp', 'hl', 'js', 'neko', 'python', 'php', 'lua', 'java', 'flash', 'eval')


def prefix(path):
    """The package a type belongs to for reporting, which is usually its first segment.

    Usually, and not always: haxe.ui lives under `haxe`, so taking one segment pulls the entire Haxe
    standard library into a section about what flixel offers. Where the first segment is one the
    standard library also occupies, the second is what identifies the owner.
    """
    parts = path.split('.')
    if parts[0] in SHARED and len(parts) > 1:
        return '.'.join(parts[:2])
    return parts[0]


def base_args(libs):
    args = ['haxe', '-lib', 'hxscript']
    for lib in libs:
        args += ['-lib', lib]

    # flixel refuses to type without its own defines macro having run.
    if 'flixel' in libs:
        args += ['--macro', 'flixel.system.macros.FlxDefines.run()']

    return args + ['-cp', os.path.join('test', 'lib')]


def read_rows(path):
    """The rows the probe wrote. A native build buffers stdout, so it writes a file instead."""
    if not os.path.isfile(path):
        return None

    out = io.open(path, encoding='utf-8', errors='replace').read()
    if '##ROWS' not in out:
        return None

    rows = []
    for line in out.split('##ROWS', 1)[1].splitlines():
        parts = line.split('\t')
        if len(parts) == 4:
            rows.append({'path': parts[0], 'kind': parts[1], 'ok': parts[2] == 'yes', 'why': parts[3]})
    return rows


def blame(text):
    lines = [l.strip() for l in text.splitlines() if ' : ' in l and 'Warning' not in l]
    return lines[0] if lines else 'the probe produced no output'


PROJECT_XML = """<?xml version="1.0" encoding="utf-8"?>
<project>
\t<meta title="hxscript probe" package="dev.hxscript.probe" version="1.0.0" company="hxscript"/>
\t<app main="ProbeApp" file="Probe" path="bin"/>
\t<source path="."/>
\t<source path="{lib}"/>
\t<window hidden="true" width="1" height="1" resizable="false" fullscreen="false"/>
{haxelibs}
\t<haxedef name="hxscript"/>
{defines}
</project>
"""

PROBE_APP = """/** Generated. A lime entry point for `Probe`, which cannot be a console program with lime in it. */
class ProbeApp extends openfl.display.Sprite {
\tpublic function new() {
\t\tsuper();

\t\ttry {
\t\t\tProbe.run(Sys.args()[0], Sys.args().slice(1));
\t\t} catch (e:Dynamic) {
\t\t\tSys.stderr().writeString(Std.string(e) + "\\n");
\t\t\tSys.exit(1);
\t\t}

\t\tSys.exit(0);
\t}
}
"""


def probe_cpp(libs, packs, wired):
    """hxcpp, which is what a desktop or mobile game is usually built as.

    A stack with lime under it is built as a lime application rather than as a console program, and
    that is not a preference. `-lib flixel -cpp` with a three-line `main` dies at `0xC0000005` before
    reaching it, because lime writes the entry point and the native wiring, and neither exists in a
    bare hxcpp binary. Copying `lime.ndll` beside the exe does not help and neither does a bigger
    stack; the application build is the only shape that runs.

    The project it builds is generated into `bin_reach` and thrown away, so nothing under `apps/` is
    involved. Its window is declared hidden, since this one writes a file and exits.
    """
    if 'lime' not in wired:
        out = os.path.join(ROOT, 'bin_reach', 'cpp')
        exe = binary('cpp', 'Probe')

        if os.path.isfile(exe):
            os.remove(exe)

        b = subprocess.run(base_args(libs) + ['-main', 'Probe', '-D', 'hxscript', '-cpp', out],
                           capture_output=True, text=True, cwd=ROOT)
        if not os.path.isfile(exe):
            return None, blame(b.stdout + b.stderr)

        return collect(exe, 'cpp', packs)

    d = os.path.join(ROOT, 'bin_reach', 'lime')
    os.makedirs(d, exist_ok=True)

    haxelibs = '\n'.join('\t<haxelib name="%s"/>' % l for l in ['hxscript'] + libs)
    defines = '\t<haxedef name="FLX_NO_DEBUG"/>' if 'flixel' in libs else ''
    io.open(os.path.join(d, 'Project.xml'), 'w', encoding='utf-8').write(
        PROJECT_XML.format(lib=os.path.join(ROOT, 'test', 'lib').replace('\\', '/'),
                           haxelibs=haxelibs, defines=defines))
    io.open(os.path.join(d, 'ProbeApp.hx'), 'w', encoding='utf-8').write(PROBE_APP)

    exe = os.path.join(d, 'bin', 'windows', 'bin', 'Probe.exe') if os.name == 'nt' \
        else os.path.join(d, 'bin', 'linux', 'bin', 'Probe')
    if os.path.isfile(exe):
        os.remove(exe)

    target = 'windows' if os.name == 'nt' else ('mac' if sys.platform == 'darwin' else 'linux')
    b = subprocess.run(['haxelib', 'run', 'lime', 'build', target],
                       capture_output=True, text=True, cwd=d)
    if not os.path.isfile(exe):
        return None, blame(b.stdout + b.stderr)

    return collect(exe, 'cpp', packs)


def probe_hlc(libs, packs):
    """HL/C: Haxe writes C, the C links into a native binary, and no VM is involved.

    The same shape `apps/sandbox-heaps` ships as, and the harder half to get right, so it is the one
    worth measuring. `-D no-compilation` stops Haxe handing the native step to the hashlink haxelib,
    because `build.sh` does that step here and has to compile hxScript's own module in alongside.
    """
    out = os.path.join(ROOT, 'bin_reach', 'hlc')
    exe = binary('hlc', 'probe')
    os.makedirs(out, exist_ok=True)

    if os.path.isfile(exe):
        os.remove(exe)

    b = subprocess.run(base_args(libs) + ['-main', 'Probe', '-D', 'hxscript', '-D', 'no-compilation',
                                          '-hl', os.path.join(out, 'main.c')],
                       capture_output=True, text=True, cwd=ROOT)
    if not os.path.isfile(os.path.join(out, 'main.c')):
        return None, blame(b.stdout + b.stderr)

    sh = unix_shell()
    if sh is None:
        return None, 'no POSIX shell to run build.sh with'

    n = subprocess.run([sh, 'src/hxscript/hl/native/build.sh', '--hlc', 'bin_reach/hlc',
                        '--out', os.path.relpath(exe, ROOT).replace('\\', '/')],
                       capture_output=True, text=True, cwd=ROOT)
    if not os.path.isfile(exe):
        tail = (n.stdout + n.stderr).strip().splitlines()
        return None, (tail[-1].strip() if tail else 'build.sh produced no binary')

    carry_runtime(hashlink_root(), out)
    return collect(exe, 'hlc', packs)


def collect(exe, name, packs):
    """Run a built probe and read back what it wrote.

    A crash is reported with the type it was on rather than as silence: the probe flushes every row,
    so the file survives the process and its last line names where it stopped.
    """
    rows_file = os.path.join(ROOT, 'bin_reach', name + '.tsv')
    if os.path.isfile(rows_file):
        os.remove(rows_file)

    r = subprocess.run([exe, rows_file] + packs, capture_output=True, text=True, cwd=ROOT)
    rows = read_rows(rows_file)

    if rows is None:
        return None, blame(r.stderr + r.stdout)

    if r.returncode != 0:
        last = rows[-1]['path'] if rows else 'nothing'
        return None, 'the probe exited %d after %d rows, last on `%s`' % (r.returncode, len(rows), last)

    return rows, None


def targets(wired):
    """Which target to build a stack as, most likely first.

    A game library picks its own target and the doc follows it rather than guessing. Anything on lime
    is an hxcpp application, which is what lime builds for desktop and mobile. heaps is a HashLink
    engine: hxcpp is not a target it supports, and asking anyway costs a full C++ build that ends in
    an error inside heaps' own generated `BufferFlags_Impl_` every single run.

    The other target is still tried if the first fails, so a stack is only reported unverified when
    neither works, but no stack pays for a build that was never going to run.
    """
    return ['cpp', 'hlc'] if 'lime' in wired else ['hlc', 'cpp']


def probe(libs, packs, wired):
    """Import every type in the build from a script, and report what a script actually got.

    This is the measurement the doc is named after. Walking the presets' roots on disk says what
    SHOULD be reachable, which is a different claim and a weaker one: it cannot see a type dead code
    elimination dropped, an abstract whose wrapper was never generated, or a typedef of a shape the
    interpreter has no representation for. All three bind an import without complaint and then answer
    nothing on first use, so the only honest way to list them is to run one.

    Both targets here are ones a game ships as, and that is the point: eval would be quicker and
    would answer a question nobody has. What a type IS does not change with the target, but what
    survives dead code elimination does, and a library is free to define a type per target as heaps
    does with `hxd.FloatBuffer`, so an answer measured on the interpreter is not an answer about a
    build anyone runs.

    Which target comes first is `targets`, and it is the stack's own choice rather than a fixed order.

    @return the rows and which target produced them, or None and why not.
    """
    build = {'cpp': lambda: probe_cpp(libs, packs, wired), 'hlc': lambda: probe_hlc(libs, packs)}
    name = {'cpp': 'hxcpp', 'hlc': 'HL/C'}
    failed = []

    for t in targets(wired):
        rows, why = build[t]()
        if rows:
            return rows, name[t], None
        failed.append('%s: %s' % (name[t], why))

    return None, None, ' -- '.join(failed)


def group(add, key, count, body):
    """One package's list as a collapsible.

    These run to a few thousand entries across the doc, and a reader wants one package of one stack.
    Collapsed, the page is a list of packages to open; expanded, it is what it always was.
    """
    add('<details>')
    add('<summary><code>%s</code> (%d)</summary>\n' % (key, count))
    for line in body:
        add(line)
    add('</details>\n')


def section(libs, add):
    """Emit one stack's section. Returns its counts for the summary."""
    w = wire(libs)
    if not w['ok']:
        sys.exit('the wiring macro did not report for %s; run the haxe command by hand to see why' % ' '.join(libs))

    # Which records are live is the macro's answer, not the command line's: naming `flixel` pulls
    # lime and openfl in transitively, and `Presets.active` tests the defines rather than the -lib
    # list. Matched on title, which is what the macro prints, and which is also the only name that
    # separates heaps' two halves.
    ps = presets()
    active = [r for r in ps.values() if r['title'] in w['wired']]
    if not active:
        sys.exit('no preset record matched what the macro wired: %r' % (w['wired'],))

    # From what was WIRED, not from the -lib list: naming `flixel` brings lime and openfl with it, and
    # a version table that lists only what was typed on the command line is missing two thirds of it.
    wanted = sorted({r['haxelib'] for r in active if r['haxelib'] != 'hxscript'})
    vers = versions(wanted)
    roots = [r for rec in active for r in rec['roots']]
    ignore = [i for rec in active for i in rec['ignore']]

    # The packages to report on, taken from what the active records actually reach for rather than
    # from the -lib list, so heaps' `hxd` and flixel's `openfl` are not lost.
    #
    # The library's own record is excluded, and not only for its `hxscript.*` helpers: it also names
    # `haxe.io.Bytes` and friends, which are the standard library rather than a game library, and
    # letting those in put five hundred `haxe.*` types into a doc about what flixel offers.
    packs = sorted({prefix(p) for rec in active if rec['title'] != 'hxscript'
                    for p in rec['roots'] + rec['types'] + rec['bases'] + rec['abstracts']
                    if not p.startswith('hxscript.')})

    rows, runtime, failed = probe(libs, packs, w['wired'])
    usable = [] if rows is None else [r for r in rows if r['ok']]
    broken = [] if rows is None else [r for r in rows if not r['ok']]

    bases = {b for _n, b in w['bridges']}
    absset = set(w['abstracts'])

    def tags(p):
        t = []
        if p in bases:
            t.append('extendable')
        if p in absset:
            t.append('wrapped')
        return t

    title = ', '.join(t for t in w['wired'] if t != 'hxscript')
    add('## %s\n' % title)
    add(STACK_TOC)
    add('')
    add('Measured against %s.\n' % ', '.join('%s %s' % (k, v) for k, v in sorted(vers.items())))
    if runtime:
        add('Imports verified by running them on **%s**.\n' % runtime)
    add('| | count | what it means |')
    add('| --- | --- | --- |')
    if rows is None:
        add('| usable | *not verified* | see below |')
        add('| **not usable** | *not verified* | see below |')
    else:
        add('| usable | %d | the `import` binds and the name has a runtime form behind it |' % len(usable))
        add('| **not usable** | %d | in the build, but a script gets nothing it can use |' % len(broken))
    add('| *extendable* | %d | has a generated bridge, so a script may `extends` it |' % len(w['bridges']))
    add('| *wrapped* | %d | an abstract given a runtime form, so its constants and operators work |' % len(absset))
    add('')

    if rows is None:
        add('> **Imports were not verified for this stack.** The probe runs every import from a real')
        add('> script, and running one needs a target this stack compiles to. This one did not build:\n')
        add('> ```')
        add('> %s' % failed)
        add('> ```\n')
        add('> The bridges and abstracts below are still measured, since those come from the wiring macro')
        add('> and need no runtime. Re-run `python test/lib/reach.py` on a machine with a runtime this')
        add('> stack supports to fill in the rest.\n')

    if w['notBridged']:
        add('**Named but not bridged:** ' + ', '.join('`%s`' % n for n in w['notBridged']) + '\n')
    else:
        add('Every base these presets name was bridged.\n')

    add('### Extendable\n')
    add('<details>')
    add('<summary><strong>%d base(s) with a generated bridge</strong></summary>\n' % len(w['bridges']))
    add('| base | generated bridge |')
    add('| --- | --- |')
    for n, b in w['bridges']:
        add('| `%s` | `hxscript.wired.%s` |' % (b, n))
    add('')
    add('</details>\n')
    if w['skipped']:
        add('<details>')
        add('<summary><strong>%d method(s) skipped on a bridge, left to <code>super</code></strong>'
            '</summary>\n' % len(w['skipped']))
        for s in w['skipped']:
            add('- %s' % s)
        add('')
        add('</details>\n')

    add('### Abstracts wrapped\n')
    add('An abstract has no runtime class of its own, so a wrapper is what gives it constants and')
    add('operators a script can reach. This is what the build asked to wrap, which is very nearly what it')
    add('got: a `private` abstract is wrapped and then unreachable anyway, since no import crosses a')
    add('module boundary to a private type, and one behind a platform gate is wrapped only on that')
    add('platform. Six of flixel\'s are one or the other.\n')
    bypkg = collections.defaultdict(list)
    for a in w['abstracts']:
        bypkg['.'.join(a.split('.')[:2])].append(a)
    for k in sorted(bypkg, key=lambda k: (-len(bypkg[k]), k)):
        group(add, k, len(bypkg[k]), ['- `%s`' % a for a in sorted(bypkg[k])] + [''])

    if rows is None:
        return {'title': title, 'usable': None, 'broken': None,
                'bridges': len(w['bridges']), 'abstracts': len(absset)}

    add('### Not usable\n')
    add('These are in the build and a script can write the `import`, and then the name answers nothing.')
    add('Every one was tried and failed. Two causes account for nearly all of them, and only one has a')
    add('fix:\n')
    add('- **An abstract with no wrapper** is one no preset asked for. Naming it in a preset\'s')
    add('  `abstracts`, or its package in `abstractPackages`, is what generates one. The exception is a')
    add('  `private` abstract, which no `import` reaches from outside its own module whatever is')
    add('  generated for it.')
    add('- **A function or anonymous shape** has no runtime form to bind at all, so there is nothing to')
    add('  turn on. `parity.md` covers what the interpreter does and does not represent.\n')
    if not broken:
        add('None.\n')
    else:
        bykind = collections.defaultdict(list)
        for r in broken:
            bykind[r['kind']].append(r)
        for k in sorted(bykind, key=lambda k: (-len(bykind[k]), k)):
            listed = sorted(bykind[k], key=lambda r: r['path'])
            group(add, k, len(listed),
                  ['| type | why |', '| --- | --- |']
                  + ['| `%s` | %s |' % (r['path'], r['why'] or 'unknown') for r in listed] + [''])

    add('### Verified imports\n')
    add('Every one of these was imported from a script and answered. Copy the path into an `import`.\n')
    add('Roots included: %s\n' % (', '.join('`%s`' % r for r in roots) if roots else '*none; every type is named individually*'))
    if ignore:
        add('Ignored within them: %s\n' % ', '.join('`%s`' % i for i in ignore))
    pk = collections.defaultdict(list)
    for r in sorted(usable, key=lambda r: r['path']):
        parts = r['path'].split('.')
        pk['.'.join(parts[:2]) if len(parts) > 2 else parts[0]].append(r['path'])
    for k in sorted(pk, key=lambda k: (-len(pk[k]), k)):
        body = []
        for path in pk[k]:
            t = tags(path)
            body.append('- `%s`%s' % (path, ('  ' + ', '.join('*%s*' % x for x in t)) if t else ''))
        group(add, k, len(pk[k]), body + [''])

    return {'title': title, 'usable': len(usable), 'broken': len(broken),
            'bridges': len(w['bridges']), 'abstracts': len(absset)}


def main():
    """One doc, one section per stack, so running it for one does not lose the other."""
    args = sys.argv[1:]
    # hxvlc and extension-haptics ride with the flixel stack because that is where a project has them,
    # and probing them separately would pay for the whole openfl build twice to report a dozen types.
    # extension-androidtools is absent on purpose: it is compilable on Android alone, so nothing on
    # this machine can run it, and listing it would produce a section of failures that say nothing
    # about the library.
    stacks = [args] if args else [['flixel', 'flixel-addons', 'flixel-ui', 'hxvlc', 'extension-haptics',
                                   'haxeui-core', 'haxeui-flixel'],
                                  ['heaps']]

    body = []
    counts = []
    for libs in stacks:
        counts.append(section(libs, body.append))

    L = ['# Verified working imports\n']
    L.append('Generated by `python test/lib/reach.py`. Do not edit.\n')
    L.append('What a script can `import` and actually use, per game library. Nothing here is read off')
    L.append('`Presets`: every type in the build was imported from a real script and the answer recorded, so a')
    L.append('path listed as usable is one that was used.\n')
    L.append('| stack | usable | not usable | extendable | wrapped |')
    L.append('| --- | --- | --- | --- | --- |')
    for c in counts:
        n = lambda v: '*not verified*' if v is None else str(v)
        L.append('| %s | %s | %s | %d | %d |'
                 % (c['title'], n(c['usable']), n(c['broken']), c['bridges'], c['abstracts']))
    L.append('')
    L.append('## Contents\n')
    L.append(TOP_TOC)
    L.append('')

    L.append('## What the markers mean\n')
    L.append('**usable**')
    L.append('The `import` binds and the name has a runtime class or enum behind it, so a script can')
    L.append('construct it, call a static on it, or hold one. This is the default and is left unmarked.\n')
    L.append('**not usable**')
    L.append('The type is in the build and the `import` line is accepted, but the name answers nothing on')
    L.append('first use. Listed per stack with the reason, and never silently omitted.\n')
    L.append('*extendable*')
    L.append('The build generated a bridge class for it, so a script may write `class Mine extends That`.')
    L.append('Without one a script still imports and constructs the type, it just cannot subclass it.\n')
    L.append('*wrapped*')
    L.append('An abstract given a generated runtime form. Abstracts have no class of their own, so without')
    L.append('this its constants and operators resolve to nothing.\n')
    L += body

    L.append('## What this does not promise\n')
    L.append('**Verified on the target named per stack, and a different target can differ.** Both are targets a')
    L.append('game ships as, hxcpp or HL/C, rather than the interpreter, because dead code elimination is a')
    L.append('property of the target and is what strips a member. What a type *is* does not change with the')
    L.append('target, so an abstract with no wrapper and a typedef of an anonymous shape fail everywhere; a')
    L.append('library defining a type per target, as heaps does with `hxd.FloatBuffer`, is where the two can')
    L.append('disagree.\n')
    L.append('**Usable is about the type, not every member on it.** Under hxcpp\'s default `-dce std` a member no')
    L.append('compiled call site happens to use is stripped, and a script reaching it gets `Cannot call null`.')
    L.append('That is a property of how the host was built rather than of this list.\n')
    L.append('**An `inline` member is never reachable**, at any DCE setting: inlining is a compile-time')
    L.append('substitution, so there is no method to reflect on. Those need an entry in `Config.callShims`.\n')
    L.append('**Nothing is imported for you.** No shipped preset offers a bare name, so a script writes its')
    L.append('own `import` for everything above, as in Haxe. A host that wants some names bare asks for them')
    L.append('by path with `Boot.importGlobals([...])`, or marks its own classes `@:scriptAmbient`.\n')
    L.append('**These lists are version-sensitive by nature**, so re-run this after a library upgrade.')

    io.open(OUT, 'w', encoding='utf-8', newline='\n').write('\n'.join(contents(L)) + '\n')
    print('wrote %s' % os.path.relpath(OUT, ROOT).replace('\\', '/'))
    for c in counts:
        state = ('imports NOT verified' if c['usable'] is None
                 else '%d usable, %d not usable' % (c['usable'], c['broken']))
        print('  %-30s %s, %d bridges, %d abstracts'
              % (c['title'], state, c['bridges'], c['abstracts']))


if __name__ == '__main__':
    main()
