package hxscript.error;

/**
 * Renders a [`Diagnostic`](Diagnostic.hx), and an [`ErrorKind`](ErrorKind.hx), as text.
 *
 * The layout is `origin:line: character n`, the quoted source line, then a caret under the column,
 * which is what editors and terminals already turn into a clickable position. Every part drops out
 * cleanly when unknown, because several phases have no source position at all.
 */
class Printer {
	/** How wide a tab is taken to be when lining the caret up under the source. */
	public static var tabWidth:Int = 4;

	/**
	 * Renders one diagnostic.
	 *
	 * @param d The diagnostic.
	 * @return The rendered block, without a trailing newline.
	 */
	public static function render(d:Diagnostic):String {
		var out:Array<String> = [];

		var head:String = position(d);
		if (head != null)
			out.push(head);

		var excerpt:String = d.excerpt != null ? d.excerpt : (d.origin != null && d.line > 0 ? Sources.line(d.origin, d.line) : null);

		if (excerpt != null) {
			out.push('  ' + expand(excerpt));

			if (d.column > 0)
				out.push('  ' + StringTools.lpad('^', ' ', caret(excerpt, d.column)));
		}

		out.push(d.message);

		if (d.hint != null)
			for (line in d.hint.split('\n'))
				out.push('  ' + line);

		if (d.stack != null)
			out.push(d.stack);

		return out.join('\n');
	}

	/**
	 * The `origin:line: character n` header, as much of it as is known.
	 *
	 * @param d The diagnostic.
	 * @return The header, or null when there is no position at all.
	 */
	static function position(d:Diagnostic):String {
		if (d.origin == null)
			return d.line > 0 ? 'line ${d.line}' + (d.column > 0 ? ': character ${d.column}' : '') : null;

		var out:String = d.origin;

		if (d.line > 0)
			out += ':${d.line}';

		out += ':';

		if (d.column > 0)
			out += ' character ${d.column}';

		return out;
	}

	/**
	 * Where the caret goes, counting a tab as `tabWidth` columns.
	 *
	 * A source line indented with tabs and a caret counted in characters do not line up, and the
	 * error appears to point several columns left of where it is. This counts the rendered width of
	 * everything before the column instead.
	 *
	 * @param excerpt The source line.
	 * @param column The 1-based column.
	 * @return How many characters wide the caret's padding should be, including the caret.
	 */
	static function caret(excerpt:String, column:Int):Int {
		var width:Int = 0;

		for (i in 0...column - 1) {
			if (i >= excerpt.length)
				break;

			width += excerpt.charCodeAt(i) == 9 ? tabWidth : 1;
		}

		return width + 1;
	}

	/**
	 * Replaces tabs with spaces so the quoted line matches what the caret was measured against.
	 *
	 * @param excerpt The source line.
	 * @return The line with tabs expanded.
	 */
	static function expand(excerpt:String):String {
		if (excerpt.indexOf('\t') < 0)
			return excerpt;

		var pad:String = StringTools.lpad('', ' ', tabWidth);
		return StringTools.replace(excerpt, '\t', pad);
	}

	/**
	 * Renders a parser/interpreter error as a human-readable message, prefixed with its source
	 * position when available.
	 *
	 * @param e The error to render.
	 * @param p The parser exception carrying origin/line, if any.
	 * @return The formatted message.
	 */
	public static function errorToString(e:ErrorKind, ?p:ParserException) {
		if (p != null)
			return errorAt(e, p.origin, p.lineNumber);

		return errorMessage(e);
	}

	/**
	 * Renders an error against a position given directly rather than read off an exception.
	 *
	 * @param e The error to render.
	 * @param origin The source origin.
	 * @param line The 1-based line number.
	 * @return The formatted message, prefixed with the position.
	 */
	public static function errorAt(e:ErrorKind, origin:String, line:Int):String {
		return origin + ":" + line + ": " + errorMessage(e);
	}

	/**
	 * @param e The error to render.
	 * @return Its text, with no position prefix.
	 */
	public static function errorMessage(e:ErrorKind):String {
		return switch (e) {
			case EImportHx: 'Only import and using is allowed in import.hx files';
			case EHasNoSuper: 'Current class does not have a super';
			case EUnknownType(t): 'Type not found: $t';
			case EUnknownField(o, f): hxscript.error.Hint.typeName(o) + ' has no field ' + f;
			case EUnrecognizedPattern(e): 'Unrecognized pattern: ' + hxscript.syntax.Printer.toString(e);
			case EInvalidChar(c): "Invalid character: '" + (StringTools.isEof(c) ? "EOF" : String.fromCharCode(c)) + "' (" + c + ")";
			case EUnexpected(s): "Unexpected token: \"" + s + "\"";
			case EUnterminatedString: "Unterminated string";
			case EUnterminatedComment: "Unterminated comment";
			case EUnterminatedRegex: "Unterminated regular expression";
			case EInvalidPreprocessor(str): "Invalid conditional expression (" + str + ")";
			case EUnknownVariable(v): "Unknown identifier: " + v;
			case EInvalidIterator(v): "Invalid iterator: " + v;
			case EInvalidOp(op): "Invalid operator: " + op;
			case EInvalidAccess(f): "Invalid access to field " + f;
			case ECustom(msg): msg;
		};
	}
}
