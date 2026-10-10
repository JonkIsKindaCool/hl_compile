package hlcompiler.cli;

using StringTools;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import hlcompiler.cli.Util.*;

class Commands {
	public static function haxeBuild(a:Args):Int {
		var mode = a.release ? "release (HashLink/C)" : "development (bytecode on the VM)";
		say('[hl_compile] build: $mode -> ' + a.target());
		var code = Util.run("haxe", a.haxeArgs());
		a.cleanup();
		return code;
	}

	public static function build(args:Array<String>):Void {
		var a = Args.parse(args, "build");
		Sys.exit(haxeBuild(a));
	}

	public static function exePath(a:Args):String {
		var dir = findBuildDir(a.outDir());
		if (dir == null)
			die('Nothing built under ${a.outDir()}/build. Run the build first.');
		return Path.join([dir, exeName(a.defines)]);
	}

	public static function programArgs(a:Args):Array<String> {
		var v:Array<String> = [];
		if (a.release)
			return a.program;
		if (a.debugPort > 0) {
			v.push("--debug");
			v.push(Std.string(a.debugPort));
			v.push("--debug-wait");
		}
		if (a.hot)
			v.push("--hot-reload");
		return v.concat(a.program);
	}

	public static function run(args:Array<String>):Void {
		var a = Args.parse(args, "run");
		var code = haxeBuild(a);
		if (code != 0)
			Sys.exit(code);
		var exe = exePath(a);
		if (a.debugPort > 0)
			say('[hl_compile] waiting for debugger on port ${a.debugPort}');
		Sys.exit(Util.run(exe, programArgs(a)));
	}

	public static function clean(args:Array<String>):Void {
		var dir = "bin";
		var runtime = false;
		var global = false;
		for (x in args) {
			switch (x) {
				case "--runtime":
					runtime = true;
				case "--global":
					global = true;
				default:
					dir = x;
			}
		}

		var targets = ["obj", ".hlc_cache", ".hlc_stamp", "hdll", "build", "injections"];
		var removed = 0;
		for (d in [dir, Path.join([dir, "release"])]) {
			for (t in targets) {
				var p = Path.join([d, t]);
				if (FileSystem.exists(p)) {
					deleteRecursive(p);
					say('removed $p');
					removed++;
				}
			}
			if (FileSystem.exists(d) && FileSystem.isDirectory(d)) {
				for (f in FileSystem.readDirectory(d)) {
					if (f.indexOf("Build-") == 0 && f.endsWith(".xml")) {
						FileSystem.deleteFile(Path.join([d, f]));
						say('removed ' + Path.join([d, f]));
						removed++;
					}
				}
			}
		}
		if (runtime) {
			var libs = Path.join([libDir, "libs"]);
			if (FileSystem.exists(libs)) {
				deleteRecursive(libs);
				say('removed $libs (the runtime and the VM are rebuilt on next use)');
				removed++;
			}
		}
		if (global) {
			var c = Sys.getEnv("HL_COMPILE_CACHE");
			if (c != null && c != "" && FileSystem.exists(c)) {
				deleteRecursive(c);
				say('removed $c');
				removed++;
			} else {
				say("HL_COMPILE_CACHE is not set: no shared cache to remove.");
			}
		}
		if (removed == 0)
			say("Nothing to clean.");
	}

	static function isJunk(path:String):Bool {
		var n = Path.withoutDirectory(path);
		return n.endsWith(".hash") || n.endsWith(".pdb") || n.endsWith(".exp") || n.endsWith(".ilk") || n.endsWith(".lib") || n == "build.log";
	}

	public static function pack(args:Array<String>):Void {
		var out = "bin";
		var name = Path.withoutDirectory(Path.removeTrailingSlashes(Sys.getCwd()));
		var dist = "dist";
		var archive = false;
		var app = false;
		var id:String = null;
		var icon:String = null;
		var i = 0;
		while (i < args.length) {
			switch (args[i]) {
				case "--name":
					name = args[++i];
				case "--dist":
					dist = args[++i];
				case "--archive" | "--zip":
					archive = true;
				case "--app":
					app = true;
				case "--id":
					id = args[++i];
				case "--icon":
					icon = args[++i];
				default:
					out = args[i];
			}
			i++;
		}

		var src = findBuildDir(out);
		if (src == null)
			die('Nothing built under $out/build. Build first (haxelib run hl_compile build <file.hxml>).');
		var target = Path.withoutDirectory(src);
		var exe = null;
		for (f in FileSystem.readDirectory(src))
			if (!FileSystem.isDirectory(Path.join([src, f]))
				&& !isJunk(f)
				&& (f == "output" || f == "output.exe" || f.indexOf(".") < 0 || f.endsWith(".exe")))
				exe = exe == null ? f : exe;

		if (app) {
			if (target.indexOf("Mac") != 0)
				die('--app creates a macOS bundle, but the build is for $target.');
			if (exe == null)
				die('No executable found in $src.');
			var bundle = Path.join([dist, name + ".app"]);
			deleteRecursive(bundle);
			var macos = Path.join([bundle, "Contents", "MacOS"]);
			var res = Path.join([bundle, "Contents", "Resources"]);
			ensureDir(macos);
			ensureDir(res);
			copyRecursive(src, macos, isJunk);
			var iconKey = "";
			if (icon != null) {
				File.copy(icon, Path.join([res, Path.withoutDirectory(icon)]));
				iconKey = '\t<key>CFBundleIconFile</key>\n\t<string>${Path.withoutDirectory(icon)}</string>\n';
			}
			var plist = '<?xml version="1.0" encoding="UTF-8"?>\n'
				+ '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
				+ '<plist version="1.0">\n<dict>\n'
				+ '\t<key>CFBundleName</key>\n\t<string>$name</string>\n'
				+ '\t<key>CFBundleExecutable</key>\n\t<string>$exe</string>\n'
				+ '\t<key>CFBundleIdentifier</key>\n\t<string>${id != null ? id : "com.example." + name}</string>\n'
				+ '\t<key>CFBundlePackageType</key>\n\t<string>APPL</string>\n'
				+ '\t<key>CFBundleVersion</key>\n\t<string>1.0</string>\n'
				+ iconKey
				+ '\t<key>NSHighResolutionCapable</key>\n\t<true/>\n'
				+ '</dict>\n</plist>\n';
			File.saveContent(Path.join([bundle, "Contents", "Info.plist"]), plist);
			say('created $bundle');
			if (archive)
				makeArchive(dist, Path.withoutDirectory(bundle), name + "-" + target);
			return;
		}

		var folderName = name + "-" + target;
		var dst = Path.join([dist, folderName]);
		deleteRecursive(dst);
		copyRecursive(src, dst, isJunk);
		say('created $dst');
		if (archive)
			makeArchive(dist, folderName, folderName);
	}

	static function makeArchive(dist:String, folderName:String, base:String):Void {
		if (isWindows()) {
			var zip = Path.join([dist, base + ".zip"]);
			var entries = new List<haxe.zip.Entry>();
			function add(path:String, rel:String):Void {
				if (FileSystem.isDirectory(path)) {
					for (f in FileSystem.readDirectory(path))
						add(Path.join([path, f]), rel + "/" + f);
				} else {
					var bytes = File.getBytes(path);
					var e:haxe.zip.Entry = {
						fileName: rel,
						fileSize: bytes.length,
						fileTime: FileSystem.stat(path).mtime,
						compressed: false,
						dataSize: bytes.length,
						data: bytes,
						crc32: haxe.crypto.Crc32.make(bytes)
					};
					haxe.zip.Tools.compress(e, 9);
					entries.add(e);
				}
			}
			add(Path.join([dist, folderName]), folderName);
			var o = File.write(zip, true);
			new haxe.zip.Writer(o).write(entries);
			o.close();
			say('created $zip');
		} else {
			var tgz = base + ".tar.gz";
			var code = Util.run("tar", ["-czf", tgz, folderName], dist);
			if (code != 0)
				die("tar failed.");
			say('created ' + Path.join([dist, tgz]));
		}
	}

	public static function vscode(args:Array<String>):Void {
		var hxml = "build.hxml";
		var force = false;
		for (x in args) {
			if (x == "--force")
				force = true;
			else
				hxml = x;
		}
		var dir = ".vscode";
		ensureDir(dir);

		var tasks = '{
	"version": "2.0.0",
	"tasks": [
		{
			"label": "hl: build",
			"type": "shell",
			"command": "haxelib run hl_compile build $hxml -debug",
			"group": { "kind": "build", "isDefault": true },
			"problemMatcher": "$$haxe-absolute"
		},
		{
			"label": "hl: debug server",
			"type": "shell",
			"command": "haxelib run hl_compile run $hxml -debug --debug 6112",
			"isBackground": true,
			"problemMatcher": {
				"owner": "hl_compile",
				"pattern": { "regexp": "^(ERROR)(.*)$$", "severity": 1, "message": 2 },
				"background": {
					"activeOnStart": true,
					"beginsPattern": "^\\\\[hl_compile\\\\] build:",
					"endsPattern": "waiting for debugger"
				}
			}
		}
	]
}
';
		var launch = '{
	"version": "0.2.0",
	"configurations": [
		{
			"name": "HashLink: build and attach",
			"type": "hl",
			"request": "attach",
			"host": "localhost",
			"port": 6112,
			"cwd": "$${workspaceFolder}",
			"preLaunchTask": "hl: debug server"
		}
	]
}
';
		function write(name:String, content:String):Void {
			var p = Path.join([dir, name]);
			if (FileSystem.exists(p) && !force) {
				say('$p already exists (use --force to overwrite).');
				return;
			}
			File.saveContent(p, content);
			say('created $p');
		}
		write("tasks.json", tasks);
		write("launch.json", launch);
		say("Install the \"HashLink Debugger\" extension and press F5. The build must use -debug for line information.");
	}

	public static function newModule(args:Array<String>):Void {
		if (args.length == 0)
			die("Usage: haxelib run hl_compile new-module <name>   (lowercase letters, digits and _)");
		var name = args[0];
		if (!~/^[a-z][a-z0-9_]*$/.match(name))
			die('"$name" is not a valid library name: use lowercase letters, digits and _, starting with a letter.');
		if (FileSystem.exists(name))
			die('The folder $name already exists.');

		var cls = pascal(name);
		ensureDir(Path.join([name, "src"]));
		ensureDir(Path.join([name, "native"]));

		File.saveContent(Path.join([name, "haxelib.json"]), '{
	"name": "$name",
	"version": "0.1.0",
	"classPath": "src/",
	"description": "",
	"license": "MIT",
	"contributors": [],
	"dependencies": { "hl_compile": "" }
}
');
		File.saveContent(Path.join([name, "hl_module.xml"]), '<hlmodule name="$name">
  <requires hl_compile="1.3.0" />

  <files>
    <compilerflag value="-I$${HLMODULE_DIR}/native" />
    <file name="native/$name.c" />
  </files>

  <!-- <target><lib name="-lz" if="linux" /></target> -->
  <!-- <pkgconfig name="zlib" if="!windows" /> -->
  <!-- <copy from="assets" to="assets" /> -->
</hlmodule>
');
		File.saveContent(Path.join([name, "native", name + ".c"]),
			'// Works in both modes: built into the executable (HashLink/C) or into $name.hdll (bytecode VM).
#define HL_NAME(n) ${name}_##n
#include <hl.h>

HL_PRIM int HL_NAME(add_one)(int x) {
	return x + 1;
}
DEFINE_PRIM(_I32, add_one, _I32)
');
		File.saveContent(Path.join([name, "src", cls + ".hx"]), 'extern class $cls {
	/** Returns x + 1, computed in C. */
	@:hlNative("$name", "add_one")
	static function addOne(x:Int):Int;
}
');
		say('created $name/');
		say('Use it from a project with:  --library $name   (or -cp ../$name/src while developing)');
		say('It is picked up automatically: its hl_module.xml adds native/$name.c to the build.');
	}
}
