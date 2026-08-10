import hxscript.compile.Cppia;
import hxscript.compile.Unit;
import hxscript.compile.Result;

/** Dumps emitted cppia for a scripted source, so the bytecode can be read directly. */
class JitProbe {
	public static function main():Void {
		var which:String = Sys.args()[0];

		var thing:String = 'package w;\nclass Thing {\n\tpublic var n:Int = 0;\n\tpublic function new() {}\n}\n';

		var bodies:Map<String, String> = [
			'ints' => 'var a:Array<Int> = [1, 2]; var s = 0; for (v in a) s += v; return s;',
			'objects' => 'var a:Array<Thing> = [new Thing()]; var s = 0; for (t in a) s += t.n; return s;',
			'objIndexed' => 'var a:Array<Thing> = [new Thing()]; var s = 0; var i = 0; while (i < a.length) { s += a[i].n; i++; } return s;',
			'objLocal' => 'var a:Array<Thing> = [new Thing()]; var t:Thing = a[0]; return t.n;',
			'objUntyped' => 'var a:Array<Thing> = [new Thing()]; var t = a[0]; return t.n;'
		];

		var body:String = bodies.get(which);
		if (body == null) {
			Sys.println('pick one of: ' + [for (k in bodies.keys()) k].join(', '));
			return;
		}

		var reader:String = 'package w;\nimport w.Thing;\nclass Reader {\n\tpublic static function go():Dynamic {\n\t\t' + body + '\n\t}\n}\n';

		var inputs:Array<Unit> = [];
		for (src in [{n: 'Thing', c: thing}, {n: 'Reader', c: reader}]) {
			inputs.push({name: src.n, decls: new hxscript.syntax.Parser().parseModule(src.c, src.n, 0, ['w'])});
		}

		var res:Result = Cppia.compile(inputs, null, [], []);
		if (res.bytes == null) {
			Sys.println('refused: ' + (res.skipped.length > 0 ? res.skipped[0].reason : '?'));
			return;
		}

		Sys.println(res.bytes.toString());
	}
}
