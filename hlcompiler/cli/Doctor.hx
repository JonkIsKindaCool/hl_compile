package hlcompiler.cli;

using StringTools;

import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import hlcompiler.cli.Util.*;

class Doctor {
	static var errors:Int = 0;
	static var warnings:Int = 0;

	static function ok(what:String, detail:String = ""):Void {
		say('  [ ok ] $what' + (detail != "" ? ' - $detail' : ""));
	}

	static function warn(what:String, hint:String):Void {
		warnings++;
		say('  [warn] $what');
		say('         $hint');
	}

	static function bad(what:String, hint:String):Void {
		errors++;
		say('  [FAIL] $what');
		say('         $hint');
	}

	static function firstLine(s:String):String {
		return s.split("\n")[0].trim();
	}

	public static function version():String {
		return libVersion();
	}

	static function libVersion():String {
		try {
			var j:Dynamic = haxe.Json.parse(File.getContent(Path.join([libDir, "haxelib.json"])));
			return Std.string(j.version);
		} catch (e:Dynamic) {
			return "?";
		}
	}

	public static function run(args:Array<String>):Void {
		var wasm = args.indexOf("--wasm") >= 0;
		var os = hostOs();
		var folder = hostFolder();

		say('hl_compile ${libVersion()} on $os ($folder)');
		say("");
		say("Tools");

		var hx = capture("haxe", ["--version"]);
		if (hx.code != 0)
			bad("haxe not found", "Install Haxe 4.2 or newer from https://haxe.org/download/");
		else {
			var v = firstLine(hx.out + hx.err);
			var major = Std.parseInt(v.split(".")[0]);
			var minor = Std.parseInt(v.split(".")[1]);
			if (major != null && (major < 4 || (major == 4 && minor != null && minor < 2)))
				warn('haxe $v', "hl_compile is meant for Haxe 4.2 or newer.");
			else
				ok("haxe", v);
		}

		var hl = capture("haxelib", ["version"]);
		if (hl.code != 0)
			bad("haxelib not found", "It comes with Haxe: check that its folder is in PATH.");
		else
			ok("haxelib", firstLine(hl.out));

		var hxcpp = capture("haxelib", ["path", "hxcpp"]);
		if (hxcpp.code != 0 || hxcpp.out.indexOf("hxcpp") < 0)
			bad("hxcpp is not installed", "haxelib install hxcpp");
		else {
			var ver = "";
			for (l in hxcpp.out.split("\n"))
				if (l.indexOf("-D hxcpp=") == 0)
					ver = l.substr("-D hxcpp=".length).trim();
			ok("hxcpp", ver);
		}

		if (os == "Windows")
			checkMsvc();
		else
			checkUnixToolchain(os);

		if (wasm) {
			var em = capture("emcc", ["--version"]);
			if (em.code != 0)
				bad("emcc (Emscripten) not found", "Needed for WebAssembly. Install the emsdk and run its env script.");
			else
				ok("emcc", firstLine(em.out));
		}

		if (which("pkg-config"))
			ok("pkg-config", "available for <pkgconfig> in hl_module.xml");
		else if (os != "Windows")
			say("  [info] pkg-config not found: only needed by modules that use <pkgconfig>.");

		say("");
		say("HashLink");
		var hlh = Path.join([libDir, "hashlink", "src", "hl.h"]);
		if (!FileSystem.exists(hlh))
			bad("HashLink sources are missing (" + Path.join([libDir, "hashlink"]) + ")", 'git -C "$libDir" submodule update --init --recursive');
		else
			ok("HashLink sources", Path.join([libDir, "hashlink"]));

		var libsDir = Path.join([libDir, "libs", folder]);
		var runtime = os == "Windows" ? "libhl.dll" : "hl.lib";
		if (FileSystem.exists(Path.join([libsDir, runtime])))
			ok("runtime for " + folder, "already built");
		else
			say('  [info] runtime for $folder is not built yet: it is built once, the first time a project needs it.');
		var vmFile = Path.join([libsDir, os == "Windows" ? "hl.exe" : "hl"]);
		if (FileSystem.exists(vmFile))
			ok("VM for " + folder, "already built");
		else
			say('  [info] the VM for $folder is built the first time you compile with --hl file.hl.');

		var machine = hostMachine();
		if (machine == "x86_64" || machine == "AMD64" || machine == "x64")
			ok("CPU", machine + " (bytecode/VM mode available)");
		else
			warn('CPU: $machine', "The HashLink JIT only supports x86-64: use --hl file.c (HashLink/C) on this machine.");

		var probe = Path.join([libDir, ".doctor_write_test"]);
		try {
			File.saveContent(probe, "x");
			FileSystem.deleteFile(probe);
			ok("library folder is writable");
		} catch (e:Dynamic) {
			bad("cannot write in " + libDir, "The runtime and the VM are built inside the library folder. Check its permissions.");
		}

		var cache = Sys.getEnv("HL_COMPILE_CACHE");
		if (cache != null && cache != "")
			say('  [info] shared compile cache: $cache');

		say("");
		if (errors > 0)
			say('$errors problem(s) must be fixed before building.');
		else if (warnings > 0)
			say('Ready, with $warnings warning(s).');
		else
			say("Everything looks good.");
		Sys.exit(errors > 0 ? 1 : 0);
	}

	static function hostMachine():String {
		if (isWindows()) {
			var a = Sys.getEnv("PROCESSOR_ARCHITEW6432");
			if (a == null)
				a = Sys.getEnv("PROCESSOR_ARCHITECTURE");
			return a == null ? "unknown" : a;
		}
		var r = capture("uname", ["-m"]);
		return r.code == 0 ? r.out.trim() : "unknown";
	}

	static function checkUnixToolchain(os:String):Void {
		var cc = capture(os == "Mac" ? "clang" : "gcc", ["--version"]);
		if (cc.code != 0 && os == "Linux")
			cc = capture("cc", ["--version"]);
		if (cc.code != 0)
			bad("C compiler not found",
				os == "Mac" ? "xcode-select --install" : "Install gcc, g++ and make (Debian/Ubuntu: sudo apt install build-essential).");
		else
			ok("C compiler", firstLine(cc.out));

		var cxx = capture(os == "Mac" ? "clang++" : "g++", ["--version"]);
		if (cxx.code != 0)
			bad("C++ compiler not found", os == "Mac" ? "xcode-select --install" : "Install g++ (Debian/Ubuntu: sudo apt install build-essential).");
		else
			ok("C++ compiler", firstLine(cxx.out));

		if (which("nm"))
			ok("nm", "used to check hdlls");
		else
			warn("nm not found", "Install binutils: hdlls cannot be checked for an embedded HashLink runtime.");
	}

	static function checkMsvc():Void {
		var pf = Sys.getEnv("ProgramFiles(x86)");
		var vswhere = pf == null ? "" : Path.join([pf, "Microsoft Visual Studio", "Installer", "vswhere.exe"]);
		if (!FileSystem.exists(vswhere)) {
			bad("Visual Studio Build Tools not found (vswhere.exe is missing)",
				'Install "Build Tools for Visual Studio" with the "Desktop development with C++" workload.');
			return;
		}
		var r = capture(vswhere, [
			"-latest",
			"-products",
			"*",
			"-requires",
			"Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
			"-property",
			"installationPath"
		]);
		var vs = r.out.trim();
		if (vs == "") {
			bad("Visual Studio has no C++ tools", 'Add the "Desktop development with C++" workload in the Visual Studio Installer.');
			return;
		}
		var vf = Path.join([vs, "VC", "Auxiliary", "Build", "Microsoft.VCToolsVersion.default.txt"]);
		if (!FileSystem.exists(vf)) {
			bad("MSVC version file not found: " + vf, "Repair the Visual Studio installation.");
			return;
		}
		var ver = File.getContent(vf).trim();
		var bin = Path.join([vs, "VC", "Tools", "MSVC", ver, "bin", "Hostx64", "x64"]);
		ok("MSVC", ver);
		for (t in ["dumpbin.exe", "lib.exe"])
			if (!FileSystem.exists(Path.join([bin, t])))
				bad('$t not found in $bin', "Repair the Visual Studio installation.");
	}
}
