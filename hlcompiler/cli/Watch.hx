package hlcompiler.cli;

using StringTools;

import haxe.io.Path;
import sys.FileSystem;
import sys.thread.Thread;
import hlcompiler.cli.Util.*;

class Watch {
	static var exts = ["hx", "hxml", "c", "cpp", "h", "hpp", "xml"];
	static var skipDirs = [
		"bin",
		"obj",
		"dist",
		".git",
		".hg",
		".svn",
		"node_modules",
		".hlc_cache",
		"hdll",
		".vscode"
	];

	static function snapshot(roots:Array<String>, outAbs:String):Map<String, Float> {
		var m = new Map<String, Float>();
		function walk(dir:String):Void {
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
				return;
			var abs = FileSystem.fullPath(dir);
			if (abs == outAbs)
				return;
			for (f in FileSystem.readDirectory(dir)) {
				var p = Path.join([dir, f]);
				if (FileSystem.isDirectory(p)) {
					if (skipDirs.indexOf(f) < 0 && !f.startsWith("."))
						walk(p);
				} else if (exts.indexOf(Path.extension(f).toLowerCase()) >= 0) {
					m.set(p, FileSystem.stat(p).mtime.getTime());
				}
			}
		}
		for (r in roots)
			walk(r);
		return m;
	}

	static function changed(a:Map<String, Float>, b:Map<String, Float>):Array<String> {
		var out = [];
		for (k in b.keys())
			if (!a.exists(k) || a.get(k) != b.get(k))
				out.push(k);
		for (k in a.keys())
			if (!b.exists(k))
				out.push(k);
		return out;
	}

	static function binarySnapshot(dir:String):String {
		if (dir == null || !FileSystem.exists(dir))
			return "";
		var parts = [];
		for (f in FileSystem.readDirectory(dir)) {
			var e = Path.extension(f).toLowerCase();
			if (e == "hdll" || f == "output" || f == "output.exe")
				parts.push(f + ":" + FileSystem.stat(Path.join([dir, f])).mtime.getTime());
		}
		parts.sort(Reflect.compare);
		return parts.join(",");
	}

	static var running:Bool = false;
	static var pidFile:String = ".hl_compile.pid";

	static function sq(s:String):String {
		return "'" + s.replace("'", "'\\''") + "'";
	}

	static function isRunning():Bool {
		return running;
	}

	static function stop():Void {
		if (!running)
			return;
		var waited = 0;
		while (!FileSystem.exists(pidFile) && waited < 40) {
			Sys.sleep(0.05);
			waited++;
		}
		if (FileSystem.exists(pidFile)) {
			var pid = sys.io.File.getContent(pidFile).trim();
			if (isWindows())
				Sys.command("cmd", ["/c", "taskkill /F /T /PID " + pid + " >nul 2>&1"]);
			else
				Sys.command("kill", ["-9", pid]);
		}
		waited = 0;
		while (running && waited < 60) {
			Sys.sleep(0.05);
			waited++;
		}
		running = false;
	}

	static function start(exe:String, args:Array<String>):Void {
		say('[watch] starting ' + exe + (args.length > 0 ? " " + args.join(" ") : ""));
		if (FileSystem.exists(pidFile))
			FileSystem.deleteFile(pidFile);
		running = true;

		if (isWindows()) {
			function psq(x:String):String {
				return "'" + x.replace("'", "''") + "'";
			}
			var argList = [for (a in args) psq(a.indexOf(" ") >= 0 ? '"' + a + '"' : a)].join(",");
			var script = "$p = Start-Process -FilePath "
				+ psq(FileSystem.fullPath(exe))
				+ (args.length > 0 ? " -ArgumentList " + argList : "")
				+ " -NoNewWindow -PassThru; $p.Id | Set-Content -Encoding ascii -Path "
				+ psq(pidFile)
				+ "; $p.WaitForExit()";
			Thread.create(() -> {
				Sys.command("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script]);
				running = false;
				if (FileSystem.exists(pidFile))
					FileSystem.deleteFile(pidFile);
			});
			return;
		}

		var cmd = ["exec", sq(exe)].concat(args.map(sq)).join(" ");
		Thread.create(() -> {
			Sys.command("sh", ["-c", 'echo $$$$ > "$pidFile"; $cmd']);
			running = false;
			if (FileSystem.exists(pidFile))
				FileSystem.deleteFile(pidFile);
		});
	}

	public static function run(args:Array<String>):Void {
		var a = Args.parse(args, "watch");
		var roots = ["."];
		for (cp in Util.parseHxml(a.hxml).classPaths)
			if (FileSystem.exists(cp))
				roots.push(cp);
		var outDir = a.outDir();
		var outAbs = FileSystem.exists(outDir) ? FileSystem.fullPath(outDir) : "";

		say('[watch] watching ${roots.join(", ")} (Ctrl+C to stop)');
		var state = snapshot(roots, outAbs);

		var firstBuild = true;
		var lastBin = "";
		while (true) {
			if (!firstBuild && a.run && !a.hot)
				stop();

			var code = Commands.haxeBuild(a);
			if (code != 0 && a.hot && isRunning()) {
				say("[watch] the build failed while the program was running: closing it and trying again (a loaded hdll cannot be overwritten).");
				stop();
				code = Commands.haxeBuild(a);
			}
			var outAbs2 = FileSystem.exists(outDir) ? FileSystem.fullPath(outDir) : "";
			if (code != 0) {
				say('[watch] the build failed (exit code $code): waiting for changes' + (a.run ? " (the program is stopped until a build succeeds)." : "."));
			} else if (a.run) {
				var exe = Commands.exePath(a);
				var bin = binarySnapshot(Path.directory(exe));
				var needRestart = !isRunning() || !a.hot || bin != lastBin;
				lastBin = bin;
				if (needRestart) {
					stop();
					start(exe, Commands.programArgs(a));
				} else {
					say("[watch] bytecode updated: the running VM reloads it (hot reload).");
				}
			}
			firstBuild = false;
			state = snapshot(roots, outAbs2);

			var files:Array<String> = [];
			while (files.length == 0) {
				Sys.sleep(0.25);
				files = changed(state, snapshot(roots, outAbs2));
			}
			Sys.sleep(0.2);
			say('[watch] changed: ' + files.slice(0, 3).join(", ") + (files.length > 3 ? ", ..." : ""));
		}
	}
}
