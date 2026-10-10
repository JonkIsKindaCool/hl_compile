package hlcompiler.cli;

using StringTools;

import haxe.io.Path;

class Args {
	public var hxml:String = null;
	public var release:Bool = false;
	public var out:String = null;
	public var debugPort:Int = 0;
	public var run:Bool = false;
	public var hot:Bool = false;
	public var extra:Array<String> = [];
	public var program:Array<String> = [];
	public var defines:Array<String> = [];

	public function new() {}

	public static function parse(args:Array<String>, command:String):Args {
		var a = new Args();
		var i = 0;
		while (i < args.length) {
			var x = args[i];
			switch (x) {
				case "--":
					a.program = args.slice(i + 1);
					i = args.length;
					continue;
				case "--release":
					a.release = true;
				case "--out":
					a.out = args[++i];
				case "--run":
					a.run = true;
				case "--hot":
					a.hot = true;
					a.run = true;
				case "--debug":
					a.debugPort = 6112;
					if (i + 1 < args.length && Std.parseInt(args[i + 1]) != null)
						a.debugPort = Std.parseInt(args[++i]);
				case "-D":
					var d = args[++i];
					a.defines.push(d);
					a.extra.push("-D");
					a.extra.push(d);
				default:
					if (a.hxml == null && x.charAt(0) != "-" && x.endsWith(".hxml"))
						a.hxml = x;
					else
						a.extra.push(x);
			}
			i++;
		}
		if (a.hxml == null)
			Util.die('Usage: haxelib run hl_compile $command <file.hxml> [options]');
		return a;
	}

	public function target():String {
		var h = Util.parseHxml(hxml);
		var base = out != null ? out : h.hl;
		if (base == null)
			Util.die('$hxml has no --hl line. Pass --out <path> (for example --out bin/main).');
		var noExt = Path.withoutExtension(base);
		if (!release)
			return noExt + ".hl";
		var dir = Path.directory(noExt);
		return Path.join([dir, "release", Path.withoutDirectory(noExt)]) + ".c";
	}

	public function outDir():String {
		var d = Path.directory(target());
		return d == "" ? "." : d;
	}

	public function haxeArgs():Array<String> {
		var h = Util.parseHxml(hxml);
		var lines = [
			for (l in h.args) if (!(l.startsWith("--hl ") || l.startsWith("-hl ") || l == "--hl" || l == "-hl")) l
		];
		lines.push("--hl " + target());
		tmp = ".hl_compile." + Path.withoutDirectory(hxml);
		sys.io.File.saveContent(tmp, lines.join("\n") + "\n");
		return [tmp].concat(extra);
	}

	var tmp:String = null;

	public function cleanup():Void {
		if (tmp != null && sys.FileSystem.exists(tmp))
			sys.FileSystem.deleteFile(tmp);
		tmp = null;
	}
}
