package hlcompiler.cli;

using StringTools;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;

typedef Hxml = {
	var args:Array<String>;
	var hl:String;
	var classPaths:Array<String>;
}

typedef Captured = {
	var code:Int;
	var out:String;
	var err:String;
}

class Util {
	public static var libDir:String = "";

	public static function say(s:String = ""):Void {
		Sys.println(s);
	}

	public static function die(msg:String):Void {
		Sys.stderr().writeString("hl_compile: " + msg + "\n");
		Sys.exit(1);
	}

	public static function hostOs():String {
		return switch (Sys.systemName()) {
			case "Windows": "Windows";
			case "Mac": "Mac";
			default: "Linux";
		}
	}

	public static function isWindows():Bool {
		return Sys.systemName() == "Windows";
	}

	public static function hostFolder():String {
		return hostOs() + "64";
	}

	public static function exeName(defines:Array<String>):String {
		var name = "output";
		for (d in defines)
			if (d.indexOf("hl_exe_name=") == 0)
				name = d.substr("hl_exe_name=".length);
		return name + (isWindows() ? ".exe" : "");
	}

	public static function capture(cmd:String, args:Array<String>):Captured {
		try {
			var p = new Process(cmd, args);
			var out = p.stdout.readAll().toString();
			var err = p.stderr.readAll().toString();
			var code = p.exitCode();
			p.close();
			return {code: code, out: out, err: err};
		} catch (e:Dynamic) {
			return {code: -1, out: "", err: Std.string(e)};
		}
	}

	public static function run(cmd:String, args:Array<String>, ?cwd:String):Int {
		var old = Sys.getCwd();
		if (cwd != null)
			Sys.setCwd(cwd);
		var code = Sys.command(cmd, args);
		Sys.setCwd(old);
		return code;
	}

	public static function which(cmd:String):Bool {
		var r = isWindows() ? capture("where", [cmd]) : capture("sh", ["-c", "command -v " + cmd]);
		return r.code == 0 && r.out.trim() != "";
	}

	public static function readFile(path:String):String {
		return File.getContent(path);
	}

	public static function ensureDir(dir:String):Void {
		if (dir == "" || FileSystem.exists(dir))
			return;
		var parent = Path.directory(dir);
		if (parent != "" && parent != dir)
			ensureDir(parent);
		FileSystem.createDirectory(dir);
	}

	public static function deleteRecursive(path:String):Void {
		if (!FileSystem.exists(path))
			return;
		if (FileSystem.isDirectory(path)) {
			for (f in FileSystem.readDirectory(path))
				deleteRecursive(Path.join([path, f]));
			FileSystem.deleteDirectory(path);
		} else {
			FileSystem.deleteFile(path);
		}
	}

	public static function copyRecursive(src:String, dst:String, ?skip:String->Bool):Void {
		if (skip != null && skip(src))
			return;
		if (FileSystem.isDirectory(src)) {
			ensureDir(dst);
			for (f in FileSystem.readDirectory(src))
				copyRecursive(Path.join([src, f]), Path.join([dst, f]), skip);
		} else {
			ensureDir(Path.directory(dst));
			if (isWindows())
				File.copy(src, dst);
			else
				Sys.command("cp", ["-p", src, dst]);
		}
	}

	public static function parseHxml(file:String):Hxml {
		var res:Hxml = {args: [], hl: null, classPaths: []};
		function read(f:String):Void {
			if (!FileSystem.exists(f))
				die('File not found: $f');
			for (raw in File.getContent(f).split("\n")) {
				var line = raw.trim();
				if (line == "" || line.charAt(0) == "#")
					continue;
				if (line.endsWith(".hxml") && line.charAt(0) != "-") {
					read(line);
					continue;
				}
				var sp = line.indexOf(" ");
				var key = sp < 0 ? line : line.substr(0, sp);
				var val = sp < 0 ? "" : line.substr(sp + 1).trim();
				switch (key) {
					case "--hl" | "-hl":
						res.hl = val;
					case "-cp" | "-p" | "--class-path":
						res.classPaths.push(val);
					default:
				}
				res.args.push(line);
			}
		}
		read(file);
		return res;
	}

	public static function findBuildDir(outDir:String):String {
		var root = Path.join([outDir, "build"]);
		if (!FileSystem.exists(root))
			return null;
		var dirs = [
			for (d in FileSystem.readDirectory(root)) if (FileSystem.isDirectory(Path.join([root, d]))) d
		];
		if (dirs.length == 0)
			return null;
		if (dirs.length == 1)
			return Path.join([root, dirs[0]]);
		return dirs.indexOf(hostFolder()) >= 0 ? Path.join([root, hostFolder()]) : Path.join([root, dirs[0]]);
	}

	public static function mtime(path:String):Float {
		return FileSystem.exists(path) ? FileSystem.stat(path).mtime.getTime() : 0.;
	}

	public static function pascal(name:String):String {
		return [for (p in name.split("_")) if (p != "") p.charAt(0).toUpperCase() + p.substr(1)].join("");
	}
}
