package hxscript.types;

import hxscript.proxy.ReflectProxy;
import hxscript.proxy.TypeProxy;
import hxscript.runtime.Interp;
import hxscript.runtime.Variable;

using StringTools;
using hxscript.types.TypeCollection;

/**
 * The interface a generated bridge class implements so a native instance can behave as a scripted
 * one: it carries the scripted class, the instance's interpreter and variables, safe-mode flags, and
 * the constructor entry point. Built automatically by `Scripted` on any implementor.
 */
@:autoBuild(hxscript.macro.Scripted.build())
interface IScriptedInstance extends ICustomReflection extends ICustomClassType {
	/** The scripted class this instance is an instance of. */
	private var __base:ScriptedClass;

	/** The instance's interpreter (its method/field scope). */
	private var __interp:hxscript.runtime.Interp;

	/** The instance's variable slots. */
	private var __vars:Map<String, hxscript.runtime.Variable>;

	/** The same slots by position, for a compiled body that reaches one without asking for it by name. */
	private var __slots:haxe.ds.Vector<hxscript.runtime.Variable>;

	/** Whether instance-method errors are caught rather than thrown. */
	private var __safe:Bool;

	/** The name of the method currently executing (for error reports). */
	private var __func:String;

	/** The instance's field names. */
	private var __fields:Array<String>;

	/**
	 * Runs the scripted constructor on a freshly-allocated instance.
	 *
	 * @param base The scripted class being instantiated.
	 * @param arguments Constructor arguments.
	 */
	private function __scriptConstruct(base:ScriptedClass, arguments:Array<Dynamic>):Void;
}
