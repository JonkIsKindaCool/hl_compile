package hlcompiler.cli;

import sys.FileSystem;

class Main {
	static function help():Void {
		Sys.println("hl_compile - build HashLink programs to native executables or run them on a precompiled VM");
		Sys.println("");
		Sys.println("Usage: haxelib run hl_compile <command> [options]");
		Sys.println("");
		Sys.println("  doctor [--wasm]                  check the compilers and the library, with fixes for what is missing");
		Sys.println("  build <file.hxml> [--release]    development build (bytecode + VM), or HashLink/C with --release");
		Sys.println("  run <file.hxml> [--release] [--debug [port]] [-- args]");
		Sys.println("                                   build and run (--debug waits for a debugger, default port 6112)");
		Sys.println("  watch <file.hxml> [--run] [--hot]");
		Sys.println("                                   rebuild when a source changes; --run restarts the program,");
		Sys.println("                                   --hot uses the VM's hot reload (experimental, implies --run)");
		Sys.println("  clean [dir] [--runtime] [--global]");
		Sys.println("                                   remove build files (--runtime: the runtime and the VM; --global: the shared cache)");
		Sys.println("  package [dir] [--name n] [--archive] [--app [--id com.x.y] [--icon f.icns]]");
		Sys.println("                                   copy a build to dist/ (--archive: .tar.gz, .zip on Windows; --app: macOS bundle)");
		Sys.println("  vscode [file.hxml] [--force]     create .vscode/tasks.json and launch.json for the HashLink debugger");
		Sys.println("  new-module <name>                create a framework skeleton with an hl_module.xml");
		Sys.println("");
		Sys.println("build, run and watch accept any other haxe argument, for example: -D hl_cflags=\"-O1\" -debug");
	}

	static function main() {
		var args = Sys.args();
		Util.libDir = Sys.getCwd();

		if (Sys.getEnv("HAXELIB_RUN") != null && args.length > 0) {
			var last = args[args.length - 1];
			if (FileSystem.exists(last) && FileSystem.isDirectory(last)) {
				Sys.setCwd(last);
				args.pop();
			}
		}

		var cmd = args.length > 0 ? args.shift() : "help";
		switch (cmd) {
			case "doctor":
				Doctor.run(args);
			case "build":
				Commands.build(args);
			case "run":
				Commands.run(args);
			case "watch":
				Watch.run(args);
			case "clean":
				Commands.clean(args);
			case "package":
				Commands.pack(args);
			case "vscode":
				Commands.vscode(args);
			case "new-module":
				Commands.newModule(args);
			case "help" | "--help" | "-h":
				help();
			case "version" | "--version":
				Sys.println(Doctor.version());
			default:
				Sys.println('Unknown command "$cmd".');
				Sys.println("");
				help();
				Sys.exit(1);
		}
	}
}
