# Shared images

Written by `setup/make-assets.py`, which computes them rather than drawing them, so this folder
carries a script instead of binaries nobody can edit. Rerun it after changing that file.

`hxd.Res` reads from here for any project without a `res/` folder of its own. A project that has one
reads that instead, not both, so a project with its own assets needs all of them there.

## logo.png, which is not here

The `base3d` example looks for `logo.png` and falls back to `panel.png` when it is missing, which is
why it renders a panel rather than the logo the Heaps sample shows.

The Heaps sample draws the Haxe logo, and that is the Haxe Foundation's mark rather than something
this repository generates. Heaps ships its own copy under `samples/res`. Copy one in here as
`logo.png` and `base3d` picks it up on the next run, with no rebuild: the templates are read from
disk.
