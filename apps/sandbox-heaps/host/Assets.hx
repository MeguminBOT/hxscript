package host;

#if heaps
import hxd.fs.LocalFileSystem;
import hxd.res.Loader;
#end
import sys.FileSystem;

/**
 * Where `hxd.Res` reads from, decided per project rather than per build.
 *
 * **heaps resolves its resource folder at compile time and this app cannot.** `hxd.Res.initLocal()`
 * is a macro: it reads `-D resourcesPath` while the program is being built and bakes the absolute
 * path of that folder into the binary. That is right for a game, whose assets are known when it is
 * compiled, and wrong for this, whose whole premise is that a project arrives afterwards.
 *
 * So the loader is built by hand instead, from an ordinary runtime call. `LocalFileSystem` takes the
 * directory as a value and already resolves a relative one against `Sys.programPath()`, which is the
 * same answer the macro would have reached and is reached late enough to be about the project that
 * is running.
 *
 * A project keeps its assets in a `res/` folder beside its `scripts/`, and gets them under the names
 * they have on disk: `hxd.Res.load('gem.png').toTile()`. A project with no `res/` of its own reads
 * the app's shared one, so an example can load something without carrying a copy of it, and so a
 * script that loads an asset before the author has made one fails by not finding a file rather than
 * by there being no loader at all.
 */
class Assets {
	/** The folder the loader is currently pointed at, so switching to the same one is free. */
	static var at:String = null;

	/** Where the app's own images live, beside the executable. */
	public static inline var SHARED:String = 'assets/res';

	/**
	 * Points `hxd.Res` at a project's assets.
	 *
	 * @param folder The project's own folder, or null for the shared assets alone.
	 */
	public static function useFor(?folder:String):Void {
		#if heaps
		var own:String = folder == null ? null : folder + '/res';
		var want:String = (own != null && isFolder(own)) ? own : shared();

		if (want == null || want == at)
			return;

		hxd.Res.loader = new Loader(new LocalFileSystem(want, null));
		at = want;
		#end
	}

	/** Forgets which folder is loaded, so the next project is pointed afresh. */
	public static function release():Void {
		at = null;
	}

	/**
	 * @return The app's shared resource folder, made when it is not there.
	 *
	 * Made rather than reported missing, for the same reason the projects folder is: `hxd.Res.loader`
	 * throws rather than answering null when nothing has set it, so a build shipped without this
	 * folder would end the process on the first script that asked whether an asset existed. An empty
	 * folder answers that question with "no", which is the truth and is survivable.
	 */
	static function shared():String {
		var path:String = studio.Projects.beside(SHARED);

		if (!isFolder(path)) {
			try {
				FileSystem.createDirectory(path);
			} catch (e:haxe.Exception) {
				return null;
			}
		}

		return isFolder(path) ? path : null;
	}

	/**
	 * @param path A directory path.
	 * @return Whether it is there. `LocalFileSystem` throws on a directory that is not, and a
	 *         project without assets is ordinary rather than an error.
	 */
	static function isFolder(path:String):Bool {
		return FileSystem.exists(path) && FileSystem.isDirectory(path);
	}
}
