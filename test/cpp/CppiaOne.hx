import hxscript.cppia.Backend;
import hxscript.compile.Result;

/**
 * Loads exactly one emitted module, to separate a bad module from bad repeated loading.
 */
class CppiaOne {
	public static function main():Void {
		var args:Array<String> = Sys.args();
		var body:String = args.length > 0 ? args[0] : 'var a = 3; var b = 4; return a * b;';
		var extra:String = args.length > 1 ? args[1] : '';
		var source:String = 'package p;\nclass T {\n' + extra + '\n\tpublic static function run():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var parser = new hxscript.syntax.Parser();
		var decls = parser.parseModule(source, 'test', 0, ['p']);
		var result:Result = Backend.compile([{name: 'p.T', decls: decls}]);

		if (result.bytes == null) {
			Sys.println('refused: ' + result.skipped[0].reason);
			return;
		}

		Sys.println('emitted ' + result.bytes.length + ' bytes');
		var module = cpp.cppia.Module.fromData(result.bytes.getData());
		Sys.println('parsed');
		module.boot();
		Sys.println('booted');
		var cls:Class<Dynamic> = module.resolveClass('p.T');
		Sys.println('resolved: ' + cls);
		var fn:Dynamic = Reflect.field(cls, 'run');
		Sys.println('field: ' + fn);
		Sys.println('via null this: ' + Reflect.callMethod(null, fn, []));
		Sys.println('via direct call: ' + fn());
	}
}
