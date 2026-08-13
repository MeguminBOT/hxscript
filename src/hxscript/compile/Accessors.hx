package hxscript.compile;

#if hxscript_cppia
import haxe.ds.StringMap;
import hxscript.syntax.Expr;

/**
 * Turns a local declared with property accessors into the calls it stands for.
 *
 * `var x(get, set)` on a local is an hscript extension: the interpreter keeps the accessors on the
 * slot and consults them on every read and write. A compiled body has no slot to hang them on, so
 * the reads and writes are rewritten into `get_x()` and `set_x(v)` here instead.
 *
 * Ahead of `Capture`, which is the only place it can go. An accessor that names its own property
 * captures it, and capture boxes a captured local into a one element array, so by the time an
 * emitter sees the body there is no identifier left to rewrite. Capture also strips the name off a
 * named local function, which is what an accessor is recognised by.
 */
class Accessors {
	/** Accessors of each local property in view, written `get|set`, innermost scope last. */
	var scopes:Array<StringMap<String>> = [];

	/** The property whose accessor is being walked, which reaches its slot rather than itself. */
	var inside:Null<String> = null;

	/**
	 * @param body A function body about to be compiled.
	 * @return The body with every local property read and write replaced by its accessor call.
	 */
	public static function apply(body:Expr):Expr {
		return declares(body) ? new Accessors().walk(body) : body;
	}

	function new() {}

	/** @return Whether anything in a tree declares a local with accessors. */
	static function declares(e:Expr):Bool {
		if (e == null)
			return false;

		switch (e.e) {
			case EVar(_, _, _, get, set, _):
				if (get != null || set != null)
					return true;
			case _:
		}

		var found:Bool = false;
		hxscript.syntax.ExprTools.iter(e, function(child:Expr):Void {
			if (!found && declares(child))
				found = true;
		});

		return found;
	}

	function walk(e:Expr):Expr {
		if (e == null)
			return null;

		switch (e.e) {
			case EBlock(list):
				scopes.push(new StringMap());
				var out:Array<Expr> = [for (item in list) walk(item)];
				scopes.pop();
				return {e: EBlock(out), pos: e.pos};

			case EVar(n, t, init, get, set, isFinal):
				var rewritten:Expr = {e: EVar(n, t, walk(init), null, null, isFinal), pos: e.pos};
				declare(n, get, set);
				return rewritten;

			case EFunction(fargs, fbody, fname, ret, id):
				var owned:Null<String> = fname == null ? null : accessorOwner(fname);
				var outer:Null<String> = inside;

				if (owned != null)
					inside = owned;

				scopes.push(new StringMap());
				for (a in fargs)
					declare(a.name, null, null);

				var walked:Expr = {e: EFunction(fargs, walk(fbody), fname, ret, id), pos: e.pos};
				scopes.pop();
				inside = outer;
				return walked;

			case EFor(v, it, body):
				var over:Expr = walk(it);
				scopes.push(new StringMap());
				declare(v, null, null);
				var walked:Expr = {e: EFor(v, over, walk(body)), pos: e.pos};
				scopes.pop();
				return walked;

			case ETry(body, v, t, ecatch, extra):
				var tried:Expr = walk(body);
				var caught:Expr = bound([v], ecatch);
				var rest = extra == null ? null : [for (x in extra) {v: x.v, t: x.t, expr: bound([x.v], x.expr)}];

				return {e: ETry(tried, v, t, caught, rest), pos: e.pos};

			case ESwitch(cond, cases, defaultExpr):
				var switched:Expr = walk(cond);
				var out = [];

				for (c in cases) {
					var names:Array<String> = [];
					for (value in c.values)
						patternNames(value, names);

					var guarded = c.guard == null ? null : bound(names, c.guard);
					out.push({values: c.values, expr: bound(names, c.expr), guard: guarded});
				}

				return {e: ESwitch(switched, out, walk(defaultExpr)), pos: e.pos};

			case EIdent(name):
				return read(name, e);

			case EBinop('=', target, value):
				var name:Null<String> = propertyNamed(target);
				if (name == null)
					return Capture.mapChildren(e, walk);

				return write(name, walk(value), e.pos);

			case EBinop(op, target, value) if (compound(op)):
				var name:Null<String> = propertyNamed(target);
				if (name == null)
					return Capture.mapChildren(e, walk);

				var joined:Expr = {e: EBinop(op.substr(0, op.length - 1), read(name, target), walk(value)), pos: e.pos};
				return write(name, joined, e.pos);

			case EUnop(op, prefix, target) if (op == '++' || op == '--'):
				var name:Null<String> = propertyNamed(target);
				if (name == null)
					return Capture.mapChildren(e, walk);

				return step(name, target, op, prefix, e.pos);

			case _:
				return Capture.mapChildren(e, walk);
		}
	}

	/**
	 * @param name The local being read.
	 * @param at The expression it was read at.
	 * @return The accessor call, the throw, or the read unchanged.
	 */
	function read(name:String, at:Expr):Expr {
		var mode:Null<String> = modeOf(name, false);

		return switch (mode) {
			case 'get' | 'dynamic': {e: ECall({e: EIdent('get_' + name), pos: at.pos}, []), pos: at.pos};
			case 'never': refuse('reading', at.pos);
			case _: {e: EIdent(name), pos: at.pos};
		}
	}

	/**
	 * The interpreter answers a property write with the slot rather than with what the setter
	 * returned, so the call is followed by the slot it left.
	 *
	 * @param name The local property being assigned to.
	 * @param value What is being assigned, already walked.
	 * @param pos Where the assignment is.
	 * @return The write in the form it takes here.
	 */
	function write(name:String, value:Expr, pos:Position):Expr {
		var mode:Null<String> = modeOf(name, true);

		return switch (mode) {
			case 'set' | 'dynamic':
				var call:Expr = {e: ECall({e: EIdent('set_' + name), pos: pos}, [value]), pos: pos};
				{e: EBlock([call, {e: EIdent(name), pos: pos}]), pos: pos};
			case 'never':
				{e: EBlock([value, refuse('writing', pos)]), pos: pos};
			case _:
				{e: EBinop('=', {e: EIdent(name), pos: pos}, value), pos: pos};
		}
	}

	/**
	 * @param name The property.
	 * @param target Where it was named.
	 * @param op `++` or `--`.
	 * @param prefix Whether the operator came first, which decides what the expression answers.
	 * @param pos Where it appears.
	 * @return The read, the write, and the value the written form has.
	 */
	function step(name:String, target:Expr, op:String, prefix:Bool, pos:Position):Expr {
		var one:Expr = {e: EConst(CInt(1)), pos: pos};
		var moved:Expr = {e: EBinop(op.charAt(0), read(name, target), one), pos: pos};
		var stored:Expr = write(name, moved, pos);

		if (!prefix)
			return {e: EBinop(op.charAt(0) == '+' ? '-' : '+', stored, one), pos: pos};

		return stored;
	}

	/**
	 * Records a local, so a name bound over a property reaches the binding rather than the accessor.
	 *
	 * @param name The local.
	 * @param get Its read accessor, or null when it has none.
	 * @param set Its write accessor, or null when it has none.
	 */
	function declare(name:String, get:Null<String>, set:Null<String>):Void {
		if (scopes.length == 0)
			scopes.push(new StringMap());

		scopes[scopes.length - 1].set(name, (get == null ? '' : get) + '|' + (set == null ? '' : set));
	}

	/**
	 * @param names Locals the expression binds over whatever they shadow.
	 * @param body Where they are bound.
	 * @return The body walked with them in scope.
	 */
	function bound(names:Array<String>, body:Expr):Expr {
		scopes.push(new StringMap());
		for (name in names)
			declare(name, null, null);

		var walked:Expr = walk(body);
		scopes.pop();
		return walked;
	}

	/** Collects the bare names a `case` pattern binds, which stand over anything they shadow. */
	function patternNames(e:Expr, into:Array<String>):Void {
		if (e == null)
			return;

		switch (e.e) {
			case EIdent(name):
				into.push(name);
			case _:
				hxscript.syntax.ExprTools.iter(e, function(child:Expr):Void {
					patternNames(child, into);
				});
		}
	}

	/** @return The throw the interpreter raises for an accessor that forbids the access. */
	function refuse(doing:String, pos:Position):Expr {
		var text:Expr = {e: EConst(CString('This expression cannot be accessed for ' + doing, false)), pos: pos};
		return {e: EThrow(text), pos: pos};
	}

	/** @return The local property an expression names, or null when it names something else. */
	function propertyNamed(e:Expr):Null<String> {
		return switch (e.e) {
			case EIdent(name): lookup(name) == null ? null : name;
			case _: null;
		}
	}

	/**
	 * @param name The local being named.
	 * @param writing Whether it is being assigned to.
	 * @return The accessor mode in force here, or null for the slot.
	 */
	function modeOf(name:String, writing:Bool):Null<String> {
		var declared:Null<String> = lookup(name);
		if (declared == null || inside == name)
			return null;

		var split:Int = declared.indexOf('|');
		return writing ? declared.substr(split + 1) : declared.substr(0, split);
	}

	/** @return The accessors declared for a local, or null when it has none in view. */
	function lookup(name:String):Null<String> {
		var i:Int = scopes.length - 1;
		while (i >= 0) {
			var found:Null<String> = scopes[i].get(name);
			if (found != null)
				return found;
			i--;
		}
		return null;
	}

	/** @return The local property a named function is the accessor of, or null when it is not one. */
	function accessorOwner(fname:String):Null<String> {
		if (fname.substr(0, 4) != 'get_' && fname.substr(0, 4) != 'set_')
			return null;

		var owned:String = fname.substr(4);
		return lookup(owned) == null ? null : owned;
	}

	/** @return Whether an operator is an assigning form this rewrites through both accessors. */
	static function compound(op:String):Bool {
		return ['+=', '-=', '*=', '/=', '%=', '<<=', '>>=', '>>>=', '|=', '&=', '^='].indexOf(op) >= 0;
	}
}
#end
