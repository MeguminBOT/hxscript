package hxscript.proxy;

#if (hl || python)
/**
 * Stand-in for `Math`, aliased as `Math` inside the interpreter on the targets that need it.
 *
 * `Math` has no runtime representation on HashLink or python, so its members cannot be reflected on.
 * `Statics.build` re-emits each one as a real field.
 */
@:build(hxscript.macro.Statics.build(Math)) class MathProxy {}
#end
