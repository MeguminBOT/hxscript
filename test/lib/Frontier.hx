/**
 * How a runner is handed one frontier case.
 *
 * No expected value, which is the whole difference from `Corpus`. What a case produces is the
 * finding rather than something to assert, so a runner records what each side did and compares them
 * to each other rather than to a number written here.
 *
 * @param label How to name it in the report.
 * @param body The method body to run.
 * @param extra Extra members of the class the body sits in.
 * @param before Declarations preceding that class.
 */
typedef Probe = (label:String, body:String, ?extra:String, ?before:String) -> Void;

/**
 * Everything worth knowing the answer to, including what does not work.
 *
 * `Corpus` is the list every backend is meant to pass, so it is green by construction and says
 * nothing about the edges. This is the other list: constructs a backend refuses, constructs where a
 * compiled answer is known to differ from an interpreted one, standard-library reach, and language
 * features nothing here claims to support. **A case failing is not a failure of this file.**
 *
 * Which is why nothing here declares what it should produce. A case whose answer nobody knows cannot
 * have one written down, and writing one down anyway is how a list like this turns back into a list
 * of things that already work. What a runner reports is what the interpreter gave, what the compiler
 * gave, and whether those two agree, and every one of those three is data.
 *
 * Read the output as three separate questions. **Refused** means the compiler would not take the
 * module, which is safe: it is interpreted instead, and costs speed. **Differs** means both ran and
 * disagreed, which is the one that matters, because a script gets a different answer depending on a
 * decision its author did not make. **Threw on both** usually means the construct is not supported
 * anywhere and the script would have to avoid it.
 */
class Frontier {
	/**
	 * Offers every case to a runner.
	 *
	 * @param probe What to do with one.
	 */
	public static function run(probe:Probe, ?section:String -> Void):Void {
		var at:String -> Void = section == null ? function(_:String):Void {} : section;

		at('numbers');
		wholeNumbers(probe);
		at('reflection');
		reflection(probe);
		at('refusals');
		refusals(probe);
		at('host');
		hostReach(probe);
		at('stdlib');
		library(probe);
		at('syntax');
		language(probe);
		at('shapes');
		shapes(probe);
	}

	/** Where an integer stops being one, which each backend answers differently. */
	static function wholeNumbers(probe:Probe):Void {
		probe('int overflow, typed local', 'var n:Int = 2147483647; return Std.string(n + 1);');
		probe('int overflow, dynamic local', 'var n:Dynamic = 2147483647; return Std.string(n + 1);');
		probe('int overflow, untyped local', 'var n = 2147483647; return Std.string(n + 1);');
		probe('int overflow through a field', 'return Std.string(big + 1);', 'static var big:Int = 2147483647;');
		probe('int underflow', 'var n:Int = -2147483648; return Std.string(n - 1);');
		probe('int multiply overflow', 'var n:Int = 100000; return Std.string(n * n);');
		probe('float to int truncation', 'return Std.string(Std.int(-3.7));');
		probe('integer division stays float', 'return Std.string(7 / 2);');
		probe('modulo of negatives', 'return Std.string(-7 % 3);');
		probe('shift past the width', 'var n:Int = 1; return Std.string(n << 33);');
	}

	/** What reflection sees, which is where a compiled value's representation shows through. */
	static function reflection(probe:Probe):Void {
		probe('bool through Reflect on a structure', 'var o = {b: true}; return Std.string(Reflect.field(o, "b"));');
		probe('bool through Reflect on an instance', 'return Std.string(Reflect.field(new T(), "flag"));', 'public var flag:Bool = true; public function new() {}');
		probe('bool field read directly', 'return Std.string(new T().flag);', 'public var flag:Bool = true; public function new() {}');
		probe('bool with no annotation', 'return Std.string(new T().loose);', 'public var loose = true; public function new() {}');
		probe('Type.getClassName of a scripted class', 'return Type.getClassName(Type.getClass(new T()));', 'public function new() {}');
		probe('Reflect.fields of a structure', 'var o = {a: 1, b: 2}; var f = Reflect.fields(o); f.sort(function(x, y) return x < y ? -1 : 1); return f.join(",");');
		probe('Reflect.hasField', 'var o = {a: 1}; return Std.string(Reflect.hasField(o, "a")) + "/" + Std.string(Reflect.hasField(o, "z"));');
		probe('Reflect.callMethod on a scripted static', 'return Std.string(Reflect.callMethod(null, twice, [21]));', 'static function twice(n:Int):Int return n * 2;');
		// Reaching through a null of a class the script named is not here, and the reason is worth
		// writing down: cppia takes the process down on all three of read, write and call, so a case
		// for them would make every run of this suite crash and resume three times. HashLink throws
		// a catchable `Null access` for each. Both are stricter than the interpreter, which answers
		// null for the read.
		// An annotated array is read as the annotation says, which is what makes a sweep over one
		// fast. A script that defeats its own annotation with a `cast` is outside what Haxe promises
		// and the two answer differently: `var all:Array<T> = cast [1, 2]; all[0].v` reads null
		// interpreted and 0 compiled, because a field known to be an `Int` comes back as one. Not a
		// case, because there is nothing there for a compiler to be held to.
		probe('a typed array of a scripted class', 'var all:Array<T> = [new T(), new T()]; all[1].v = 5; return Std.string(all[0].v + all[1].v);',
			'public var v:Int = 2; public function new() {}');
		probe('a typed array holding a null', 'var all:Array<T> = [null]; return Std.string(all[0]);',
			'public var v:Int = 0; public function new() {}');
		probe('Reflect.fields of a scripted instance',
			'var f = Reflect.fields(new T()); f.sort(function(x, y) return x < y ? -1 : 1); return f.join(",");',
			'public var a:Int = 1; public var b:String = "x"; public function new() {} public function m():Int return 2;');
		probe('Std.string of a scripted instance', 'return Std.string(new T()).length > 0 ? "something" : "nothing";', 'public function new() {}');
		probe('a scripted toString is what renders it', 'return Std.string(new T());',
			'public var n:Int = 3; public function new() {} public function toString():String return "T(" + n + ")";');
		probe('Std.string of an enum value', 'return Std.string(One);', null, 'enum E { One; Two(n:Int); }');
	}

	/** The constructs one backend or another is known to refuse. */
	static function refusals(probe:Probe):Void {
		probe('inline type declaration', 'var v:{a:Int} = {a: 7}; return Std.string(v.a);');
		probe('local property accessor', 'var x(get, never):Int; function get_x() return 7; return Std.string(x);');
		probe('local property setter',
			'var x(default, set):Int = 1; var seen = 0; function set_x(n:Int) { seen = n * 2; return x = n; } x = 5; return Std.string(seen);');
		probe('local property both accessors',
			'var held = 3; var x(get, set):Int; function get_x() return held; function set_x(n:Int) return held = n; x = 8; return Std.string(x);');
		probe('local property compound assignment',
			'var held = 3; var x(get, set):Int; function get_x() return held; function set_x(n:Int) return held = n; x += 4; return Std.string(x);');
		probe('local property read is never', 'var x(never, default):Int; return Std.string(x);');
		probe('local property write is never', 'var x(default, never):Int; x = 3; return Std.string(x);');
		probe('local property accessor reads its own slot',
			'var x(get, never):Int = 5; function get_x() return x + 1; return Std.string(x);');
		probe('an argument shadowing a local property',
			'var x(get, never):Int; function get_x() return 7; function twice(x:Int) return x * 2; return Std.string(twice(4));');
		probe('a loop variable shadowing a local property',
			'var x(get, never):Int; function get_x() return 7; var n = 0; for (x in 1...4) n += x; return Std.string(n);');
		probe('a catch variable shadowing a local property',
			'var x(get, never):Int; function get_x() return 7; try { throw "boom"; } catch (x:String) { return x; } return "no";');
		probe('mixed array and map literal', 'var m = [1 => 2, 3]; return Std.string(m);');
		probe('a property declared dynamic', 'return Std.string(v);', 'public static var v(dynamic, never):Int; static function get_v() return 7;');
		probe('a property declared null', 'return Std.string(new T().v);', 'public var v(null, null):Int = 7; public function new() {}');
		probe('a property declared null read through this', 'return Std.string(new T().mine());',
			'public var v(null, null):Int = 7; public function new() {} public function mine():Int return v;');
		probe('a property through Reflect.field', 'return Std.string(Reflect.field(new T(), "v"));',
			'public var v(get, never):Int; function get_v() return 7; public function new() {}');
		probe('a get set property through Reflect.field', 'return Std.string(Reflect.field(new T(), "v"));',
			'public var v(get, set):Int; var held:Int = 3; function get_v() return held; function set_v(n:Int) return held = n; public function new() {}');
		probe('a default null property through Reflect.field', 'return Std.string(Reflect.field(new T(), "v"));',
			'public var v(default, null):Int = 7; public function new() {}');
		probe('an isVar property through Reflect.field', 'return Std.string(Reflect.field(new T(), "v"));',
			'@:isVar public var v(get, set):Int = 7; function get_v() return v; function set_v(n:Int) return v = n; public function new() {}');
		probe('a property read inside its own class', 'return Std.string(new T().doubled());',
			'public var v(get, never):Int; function get_v() return 7; public function doubled():Int return v * 2; public function new() {}');
		probe('super as a value, not a call', 'return new Child().grab();', null,
			'class Base { public function new() {} public function speak():String return "base"; }\n'
			+ 'class Child extends Base { public function new() { super(); } '
			+ 'public function grab():String { var f = super.speak; return f(); } }');
		probe('extends a host class', 'var v = new Sub(); return Std.string(v.doubled(4));', null,
			'class Sub extends HostBase { public function new() { super(); } public function doubled(n:Int):Int return n * 2 + tell(); }');
		probe('rest arguments', 'return Std.string(total(1, 2, 3));', 'static function total(...rest:Int):Int { var n = 0; for (v in rest) n += v; return n; }');
		probe('a static extension on an unknown receiver', 'var v:Dynamic = "ab"; return v.twice();', null,
			'using Frontier.Ext;');
		probe('a typed catch on a scripted class', 'try { throw new Boom(); } catch (e:Boom) { return "caught"; } return "no";', null,
			'class Boom { public function new() {} }');
	}

	/** Reaching the host, which is where the two compilers differ most in mechanism. */
	static function hostReach(probe:Probe):Void {
		/*
			A host abstract with an `inline function new`, which is what every geometry type in a game
			framework is: `h3d.Vector`, `h3d.Matrix` and `h2d.col.Point` are all this shape, and between
			them they are what every position, transform and bounds test is written in.

			All of these pass interpreted, on all three interpreters. The constructor assigns to
			`this`, so it has nowhere to live as a method and Haxe emits it as a static `_new` on the
			implementation class, which is what the wrapper now names and `AbstractTools` now calls.

			Both compilers decline a module that constructs one, so these read as refusals rather than
			as answers. Construction is not what is missing: a bare `@:forward` generates no member per
			forwarded field, so `v.x` is a question asked at access time, and compiled code resolves an
			offset and finds nothing there. Reaching a forwarded member from compiled code is what
			would let these compile, and until then declining is what keeps them from answering 0 where
			the interpreter answers 7.
		*/
		probe('a host abstract constructed', 'var v = new HostVec(3, 4); return Std.string(v);', null, 'import HostVec;');
		probe('a host abstract property', 'var v = new HostVec(3, 4); return Std.string(v.length);', null, 'import HostVec;');
		probe('a host abstract field', 'var v = new HostVec(3, 4); return Std.string(v.x + v.y);', null, 'import HostVec;');
		probe('a host abstract operator', 'var v = new HostVec(2, 3); return Std.string(v * 2);', null, 'import HostVec;');
		probe('a host abstract in an array', 'var all = [new HostVec(1, 1), new HostVec(2, 2)]; return Std.string(all[1]);', null,
			'import HostVec;');

		// An operator on a value bound as a parameter rather than declared as a local, which was put
		// down as a second gap behind the first and was not one: binding keeps the wrapper, so making
		// construction work made these work with it.
		probe('an abstract operator on a parameter', 'return Std.string(twice(new HostVec(1, 2)));',
			'static function twice(v:HostVec):HostVec { return v * 2; }', 'import HostVec;');
		probe('an abstract method taking its own abstract', 'var a = new HostVec(1, 2); return Std.string(a.plus(a));', null, 'import HostVec;');
		probe('a field of an abstract bound as a parameter', 'return Std.string(first(new HostVec(3, 4)));',
			'static function first(v:HostVec):Float { return v.x; }', 'import HostVec;');
		probe('an abstract returned through a declared return type', 'return Std.string(make(2, 5));',
			'static function make(x:Float, y:Float):HostVec { return new HostVec(x, y); }', 'import HostVec;');
		/*
			An own method called by bare name from inside a closure, which is what every event handler
			in an interface is: `hit.onClick = function(e) tapped();`. A lambda is emitted with no
			receiver, so a name that is a member of the class around it resolves to nothing and the
			module is refused. Written out because the sandbox's widgets template is refused for
			exactly this and it is the most ordinary line in it.
		*/
		probe('an own method called from a closure', 'var t = new T(); var f = t.go(); f(); f(); return Std.string(t.count);',
			'public var count:Int = 0;
public function new() {}
function bump():Void { count++; }
public function go():Dynamic { return function() { bump(); }; }');
		probe('an own field read from a closure', 'var t = new T(); return Std.string(t.read()());',
			'var held:Int = 7;
public function new() {}
public function read():Dynamic { return function() { return held; }; }');
		/*
			A host enum abstract's constructor, named three ways. The sandbox reads one of these as
			null on HashLink and the same constant written out in full as the constant, so what these
			separate is the naming rather than the type: bare after an import, through the type after
			an import, and through the type without one.
		*/
		/*
			An enum abstract's own accessor, read off a value. `HostAxes` declares `x` beside the constant
			`X`, which is `flixel.util.FlxAxes`'s shape and not a rare one. The interpreter runs the
			accessor; compiled code reads the wrapper by reflection and gets null, so this is a real
			difference rather than a refusal, and it is here to be read rather than to pass.
		*/
		probe('an enum abstract accessor on a value', 'var a:HostAxes = HostAxes.XY; return Std.string(a.x);', null, 'import HostAxes;');

		probe('an enum abstract constructor, bare', 'return Std.string(Add);', null, 'import HostFlag;');
		probe('an enum abstract constructor, through an import', 'return Std.string(HostFlag.Add);', null, 'import HostFlag;');
		probe('an enum abstract constructor, unimported', 'return Std.string(HostFlag.Add);');
		/*
			The same table read a second way. An enum abstract's constant is not the only thing an
			import binds as a mirror rather than as a value: `import Pack.Type.field` binds one too,
			and so does every module-level field. These separate the two halves of what a backend has
			to do with one, because they are opposites: a constant may be taken once and kept, and a
			static something writes may not, and reading the mirror itself is wrong for both.
		*/
		probe('a host static by bare name after a static import', 'return Std.string(step);', null, 'import HostDial.step;');
		probe('a host static written then read by bare name', 'HostDial.turns = 5; return Std.string(turns);', null, 'import HostDial.turns;');
		probe('a host static written then read qualified', 'HostDial.turns = 6; return Std.string(HostDial.turns);');
		probe('a host static read', 'return Std.string(Math.PI > 3);');
		probe('a host static that changes', 'var a = Std.string(Date.now().getTime() > 0); return a;');
		probe('a host method on a value', 'return "ab".toUpperCase();');
		probe('a host class constructed', 'var b = new StringBuf(); b.add("hi"); return b.toString();');
		probe('a host enum value', 'return Std.string(haxe.ds.Option.None);');
		/*
			The same enum named three shorter ways. The sandbox reads `BlendMode.Add` as null after
			importing it and the same constructor written out in full as the constructor, and
			`h2d.BlendMode` is an ordinary enum rather than the enum abstract it was first put down
			as, so what these ask about is a plain enum reached by a short name.
		*/
		probe('a host enum through an import', 'return Std.string(Option.None);', null, 'import haxe.ds.Option;');
		probe('a host enum constructor bare after an import', 'return Std.string(None);', null, 'import haxe.ds.Option;');
		probe('a host enum constructor with arguments through an import', 'return Std.string(Option.Some(3));', null, 'import haxe.ds.Option;');
		probe('a host enum matched', 'var o = haxe.ds.Option.Some(7); switch (o) { case Some(v): return Std.string(v); case None: return "none"; }');
		probe('an abstract Map through its alias', 'var m:Map<String, Int> = new Map(); m.set("a", 1); return Std.string(m.get("a"));');
		probe('Lambda over an array', 'return Std.string(Lambda.count([1, 2, 3]));');
		probe('haxe.Json round trip', 'return haxe.Json.stringify({a: 1});');
		probe('StringTools through using', 'return StringTools.hex(255);');
	}

	/** How far the standard library reaches from a script. */
	static function library(probe:Probe):Void {
		probe('Math functions', 'return Std.string(Math.round(Math.abs(-3.6)));');
		probe('String.fromCharCode', 'return String.fromCharCode(65);');
		probe('array sort with a closure', 'var a = [3, 1, 2]; a.sort(function(x, y) return x - y); return a.join(",");');
		probe('array filter and map', 'return [1, 2, 3, 4].filter(function(v) return v % 2 == 0).map(function(v) return v * 10).join(",");');
		probe('string split and join', 'return "a,b,c".split(",").join("-");');
		probe('substring and indexOf', 'var s = "hello"; return s.substr(1, 3) + "/" + s.indexOf("l");');
		probe('an iterator by hand', 'var it = [1, 2, 3].iterator(); var n = 0; while (it.hasNext()) n += it.next(); return Std.string(n);');
		probe('a custom iterator', 'var n = 0; for (v in new Counter(3)) n += v; return Std.string(n);', null,
			'class Counter { var at:Int = 0; var max:Int; public function new(max:Int) { this.max = max; } '
			+ 'public function hasNext():Bool return at < max; public function next():Int return at++; }');
		probe('haxe.ds.StringMap directly', 'var m = new haxe.ds.StringMap(); m.set("k", 5); return Std.string(m.get("k"));');
		probe('Std.parseInt and parseFloat', 'return Std.string(Std.parseInt("42")) + "/" + Std.string(Std.parseFloat("1.5"));');
	}

	/** Language features at the edge of what a tree-walking interpreter reaches. */
	static function language(probe:Probe):Void {
		probe('a type parameter on a class', 'var b = new Box(7); return Std.string(b.get());', null,
			'class Box<T> { var v:T; public function new(v:T) { this.v = v; } public function get():T return v; }');
		probe('a type parameter on a method', 'return Std.string(pick(7));', 'static function pick<T>(v:T):T return v;');
		probe('an interface with a default method', 'return new Impl().name();', null,
			'interface Named { public function name():String; }\n'
			+ 'class Impl implements Named { public function new() {} public function name():String return "impl"; }');
		probe('an abstract over a class', 'var w = new Wrap(); return Std.string(w.n);', null,
			'class Inner { public var n:Int = 7; public function new() {} }\n'
			+ 'abstract Wrap(Inner) { public function new() { this = new Inner(); } '
			+ 'public var n(get, never):Int; function get_n() return this.n; }');
		probe('a static inline function', 'return Std.string(twice(21));', 'static inline function twice(n:Int):Int return n * 2;');
		probe('a final field written twice', 'var t = new T(); return Std.string(t.v);', 'public final v:Int = 7; public function new() {}');
		probe('an enum abstract declared in the script', 'return Std.string(Colour.Red);', null,
			'enum abstract Colour(String) { var Red = "red"; var Blue = "blue"; }');
		probe('a recursive enum', 'var t = Node(Leaf, Leaf); return Std.string(depth(t));', 'static function depth(t:Tree):Int { return switch (t) { case Leaf: 1; case Node(a, b): 1 + depth(a); } }',
			'enum Tree { Leaf; Node(a:Tree, b:Tree); }');
		probe('a switch returning from every branch', 'var n = 2; switch (n) { case 1: return "a"; case 2: return "b"; default: return "c"; }');
		probe('deeply nested closures', 'var a = function() return function() return function() return 7; return Std.string(a()()());');
	}

	/** Shapes a real application produces that a small test rarely does. */
	static function shapes(probe:Probe):Void {
		probe('a long if-else chain', 'var n = 7; if (n == 1) return "a"; else if (n == 2) return "b"; else if (n == 7) return "g"; else return "z";');
		probe('a loop with two counters', 'var a = 0; var b = 0; for (i in 0...20) { a += i; if (i % 2 == 0) b += i; } return a + "/" + b;');
		probe('a method chain', 'return "  padded  ".split(" ").filter(function(s) return s.length > 0).join("|");');
		probe('a static holding state across calls', 'bump(); bump(); return Std.string(count);', 'static var count:Int = 0; static function bump() count++;');
		probe('an instance mutated in a loop', 'var t = new T(); for (i in 0...5) t.add(i); return Std.string(t.total);',
			'public var total:Int = 0; public function new() {} public function add(n:Int) total += n;');
		probe('an array of instances', 'var all = []; for (i in 0...3) all.push(new T(i)); var n = 0; for (t in all) n += t.v; return Std.string(n);',
			'public var v:Int; public function new(v:Int = 1) { this.v = v; }');
		probe('a null field read', 'var t = new T(); return t.maybe == null ? "null" : "set";', 'public var maybe:String; public function new() {}');
		probe('a string built from many parts', 'var s = ""; for (i in 0...5) s += i + ":"; return s;');
		probe('throwing across two frames', 'try { outer(); } catch (e:Dynamic) { return "caught " + Std.string(e); } return "no";',
			'static function inner() { throw "deep"; } static function outer() { inner(); }');
		probe('a closure stored on an instance', 'var t = new T(); t.fn = function(n:Int) return n * 3; return Std.string(t.fn(7));',
			'public var fn:Int->Int; public function new() {}');
	}
}

/** A static extension, for the case that reaches one through a receiver of unknown type. */
class Ext {
	public static function twice(s:String):String {
		return s + s;
	}
}
