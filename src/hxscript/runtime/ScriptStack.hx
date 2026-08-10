package hxscript.runtime;

/**
 * One interpreter stack frame: its local variables and the call-site descriptor.
 *
 * A `@:structInit` class rather than an anonymous structure, for the same reason as `Variable`: a
 * frame is allocated and its fields read on every call, and anonymous structures resolve fields by
 * name at runtime on static targets. `@:structInit` keeps the `{locals: ..., item: ...}` syntax.
 */
@:structInit
class StackFrame {
	/** The frame's local variables. */
	public var locals:Map<String, Variable>;

	/** What the frame represents (script, module, method, ...). */
	public var item:StackItem;
}

/** The interpreter's own call stack, used for scoping locals and rendering script traces. */
class ScriptStack {
	/** The frames, innermost last. */
	public var stack:Array<StackFrame>;

	/** Number of frames on the stack. */
	public var length(get, never):Int;

	/** @return The number of frames. */
	inline function get_length():Int
		return stack.length;

	/** @return The innermost (top) frame. */
	public inline function last() {
		return stack[stack.length - 1];
	}

	/** @return The outermost (bottom) frame. */
	public inline function first() {
		return stack[0];
	}

	/** @return A `Called from ...` trace of every frame. */
	public function toString():String {
		var b = new StringBuf();
		for (s in stack) {
			b.add('\nCalled from ');
			itemToString(b, s.item);
		}
		return b.toString();
	}

	/** Creates an empty stack. */
	public function new() {
		stack = [];
	}

	/**
	 * Trims the tail of this stack that matches the frames of another, so a captured stack can be
	 * reported relative to a baseline.
	 *
	 * @param stack The baseline stack to subtract.
	 * @return This stack, truncated in place.
	 */
	public function subtract(stack:ScriptStack):ScriptStack {
		var startIndex = -1;
		var i = -1;
		while (++i < this.length) {
			for (j in 0...stack.length) {
				if (equalItems(this.stack[i].item, stack.stack[j].item)) {
					if (startIndex < 0)
						startIndex = i;
					++i;
					if (i >= this.length)
						break;
				} else {
					startIndex = -1;
				}
			}
			if (startIndex >= 0)
				break;
		}
		if (startIndex >= 0)
			this.stack = this.stack.slice(0, startIndex);
		return this;
	}

	/** @return A shallow copy sharing the same frame objects. */
	public inline function copy():ScriptStack {
		var copy:ScriptStack = new ScriptStack();
		copy.stack = stack.copy();
		return copy;
	}

	/**
	 * Structural equality of two stack items.
	 *
	 * @param item1 The first item.
	 * @param item2 The second item.
	 * @return True if they describe the same call site.
	 */
	static function equalItems(item1:Null<StackItem>, item2:Null<StackItem>):Bool {
		return switch ([item1, item2]) {
			case [null, null]: true;
			case [SScript(m1), SScript(m2)]:
				m1 == m2;
			case [SModule(m1), SModule(m2)]:
				m1 == m2;
			case [SFilePos(item1, file1, line1, col1), SFilePos(item2, file2, line2, col2)]: file1 == file2 && line1 == line2 && col1 == col2 && equalItems(item1,
					item2);
			case [SMethod(class1, method1), SMethod(class2, method2)]: class1 == class2 && method1 == method2;
			case [SLocalFunction(v1), SLocalFunction(v2)]:
				v1 == v2;
			case _: false;
		}
	}

	/**
	 * Appends a human-readable rendering of one stack item to a buffer.
	 *
	 * @param b The buffer to append to.
	 * @param s The stack item to render.
	 */
	static function itemToString(b:StringBuf, s) {
		switch (s) {
			case SScript(s):
				b.add('script ');
				b.add(s);
			case SModule(m):
				b.add('module ');
				b.add(m);
			case SFilePos(s, file, line, col):
				if (s != null) {
					itemToString(b, s);
					b.add(' (');
				}
				b.add(file);
				b.add(' line ');
				b.add(line);
				if (col != null) {
					b.add(' column ');
					b.add(col);
				}
				if (s != null)
					b.add(')');
			case SMethod(cname, method):
				b.add(cname == null ? '<unknown>' : cname);
				b.add('.');
				b.add(method);
			case SLocalFunction(n):
				b.add('local function #');
				b.add(n);
		}
	}
}

/** What a call-stack frame represents. */
enum StackItem {
	/** A top-level script body. */
	SScript(s:String);

	/** A module's top-level program. */
	SModule(m:String);

	/** A source position, optionally wrapping the item it belongs to. */
	SFilePos(s:Null<StackItem>, file:String, line:Int, ?column:Int);

	/** A method call on a (possibly unknown) class. */
	SMethod(classname:Null<String>, method:String);

	/** A local (anonymous) function, identified by its runtime slot. */
	SLocalFunction(?v:Int);
}
