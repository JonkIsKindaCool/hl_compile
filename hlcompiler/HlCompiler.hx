package hlcompiler;

#if macro
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import haxe.macro.Context;
import haxe.macro.Compiler;

using StringTools;

typedef NativeLib = {
	var id:String;
	var fileName:String;
	var path:String;
	var isStatic:Bool;
}

typedef NativeLibs = {
	var statics:Array<NativeLib>;
	var dynamics:Array<NativeLib>;
	var shadowed:Array<NativeLib>;
	var staticDir:String;
	var dynamicDir:String;
}

class HlCompiler {
	public static var os:String;
	public static var arch:String;
	public static var folder:String;
	public static var haxelibPath:String;

	public static var hlIncludeDir:String;
	public static var hlLibDir:String;
	public static var hlLibFile:String;
	public static var hlDllFile:String;

	static inline var TAG:String = "hlcompiler";

	public static function init():Void {
		nativeLibsCache = null;
		haxelibPath = getHaxelibPath();

		if (Context.defined("hl_force_webassembly")
			|| Context.defined("hl_force_emscripten")
			|| Context.defined("emscripten")
			|| Context.defined("webassembly")
			|| Context.defined("wasm"))
			os = "WebAssembly";
		else if (Context.defined("hl_force_windows"))
			os = "Windows";
		else if (Context.defined("hl_force_linux"))
			os = "Linux";
		else if (Context.defined("hl_force_mac"))
			os = "Mac";
		else if (Context.defined("hl_force_ios"))
			os = "iPhone";
		else if (Context.defined("hl_force_android"))
			os = "Android";
		else {
			os = switch (Sys.systemName()) {
				case "Windows": "Windows";
				case "Linux": "Linux";
				case "Mac": "Mac";
				default:
					fail('Unsupported platform: ${Sys.systemName()}');
					"";
			}
		}

		var arm64:Bool = Context.defined("hl_compile_arm64");
		var arm7:Bool = Context.defined("hl_compile_arm7");
		var arm:Bool = Context.defined("hl_compile_arm");
		var x86:Bool = Context.defined("hl_compile_x86");
		var x64:Bool = Context.defined("hl_compile_x64");

		var count:Int = [arm64, arm7, arm, x86, x64].filter(function(v:Bool) return v).length;
		if (count > 1)
			fail('Only one architecture can be defined');

		if (os == "WebAssembly") {
			arch = "";
		} else if (arm64 || arm)
			arch = "Arm64";
		else if (arm7)
			arch = "Arm7";
		else if (x86)
			arch = "32";
		else
			arch = "64";

		folder = os + arch;
		hlIncludeDir = Path.join([haxelibPath, "hashlink", "src"]);
		hlLibDir = Path.join([haxelibPath, "libs", folder]);
		if (os == "WebAssembly") {
			hlLibFile = Path.join([hlLibDir, "hl.a"]);
		} else if (os == "Windows") {
			hlLibFile = Path.join([hlLibDir, "libhl.lib"]);
		} else {
			hlLibFile = Path.join([hlLibDir, "hl.lib"]);
		}
		hlDllFile = Path.join([hlLibDir, "libhl.dll"]);
		if (os == "WebAssembly" && !FileSystem.exists(hlLibFile)) {
			var altLib = Path.join([hlLibDir, "libhl.a"]);
			if (FileSystem.exists(altLib))
				hlLibFile = altLib;
		}

		if (!Context.defined("no-compilation"))
			Compiler.define("no-compilation");

		Context.onAfterGenerate(() -> build());
	}

	static function build():Void {
		var old:String = Sys.getCwd();

		if (!isHashlinkCompiled()) {
			info('Hashlink runtime not found. Building it first...');
			Sys.setCwd(haxelibPath);
			compileBuildXml(haxelibPath, "BuildHashlink.xml");
			Sys.setCwd(old);
		}

		if (os == "WebAssembly") {
			if (FileSystem.exists(Path.join([hlLibDir, "hl.a"]))) {
				hlLibFile = Path.join([hlLibDir, "hl.a"]);
			} else if (FileSystem.exists(Path.join([hlLibDir, "libhl.a"]))) {
				hlLibFile = Path.join([hlLibDir, "libhl.a"]);
			}
		}

		if (os == "Windows")
			ensureRuntimeImportLib();

		var outputDir:String = getGeneratedOutputDir();
		info('Target platform: $os' + (arch != "" ? ' ($arch)' : ''));
		info('Output directory: $outputDir');

		var cacheDir:String = resolveCacheDir(outputDir);
		var xmlPath:String = generateBuildXml(old, outputDir, cacheDir != null);

		var stampFile:String = Path.join([outputDir, ".hlc_stamp"]);
		var exeFile:String = Path.join([outputDir, "build", folder, exeFileName()]);
		var stamp:String = computeStamp(outputDir, xmlPath, resolveNativeLibs(old));

		if (!Context.defined("hl_force") && FileSystem.exists(exeFile) && FileSystem.exists(stampFile) && File.getContent(stampFile) == stamp) {
			info('Up to date: nothing changed since the last build, native build skipped (-D hl_force to rebuild).');
		} else {
			if (FileSystem.exists(stampFile))
				FileSystem.deleteFile(stampFile);
			compileBuildXml(old, xmlPath, outputDir, cacheDir);
			File.saveContent(stampFile, stamp);
		}

		copyHdlls(old, outputDir);
		info('Build completed successfully.');
	}

	static function isHashlinkCompiled():Bool {
		if (os == "WebAssembly") {
			return FileSystem.exists(Path.join([hlLibDir, "hl.a"]))
				|| FileSystem.exists(Path.join([hlLibDir, "libhl.a"]))
				|| FileSystem.exists(hlLibFile);
		}
		if (os == "Windows")
			return FileSystem.exists(hlDllFile);
		return FileSystem.exists(hlLibFile);
	}

	static function ensureRuntimeImportLib():Void {
		if (!FileSystem.exists(hlDllFile))
			fail('libhl.dll was not produced: $hlDllFile');

		if (FileSystem.exists(hlLibFile) && FileSystem.stat(hlLibFile).mtime.getTime() >= FileSystem.stat(hlDllFile).mtime.getTime())
			return;

		info('Generating import lib for libhl.dll...');
		var defPath:String = Path.join([hlLibDir, "libhl.def"]);
		writeImportLib("libhl.dll", readExports(hlDllFile), defPath, hlLibFile);
	}

	static function getGeneratedOutputDir():String {
		var output:String = Compiler.getOutput();
		if (output == null)
			fail('No output detected. Did you compile with -hl <file>?');

		var dir:String = Path.directory(Path.normalize(output));
		if (!FileSystem.exists(dir))
			fail('Output directory does not exist: $dir');

		return dir;
	}

	static var nativeLibsCache:NativeLibs = null;

	static inline function staticLibExt():String {
		return os == "Windows" ? "lib" : "a";
	}

	static function nativeLibId(fileName:String, isStatic:Bool):String {
		var id:String = Path.withoutExtension(fileName);
		if (isStatic) {
			if (id.endsWith("_static"))
				id = id.substr(0, id.length - "_static".length);
			if (os != "Windows" && id.startsWith("lib") && id.length > 3)
				id = id.substr(3);
		}
		return id;
	}

	static function listFilesWithExt(dir:String, ext:String):Array<String> {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return [];
		var files:Array<String> = FileSystem.readDirectory(dir)
			.filter(f -> Path.extension(f).toLowerCase() == ext && !FileSystem.isDirectory(Path.join([dir, f])));
		files.sort(Reflect.compare);
		return files;
	}

	static function resolveNativeLibs(p:String):NativeLibs {
		if (nativeLibsCache != null)
			return nativeLibsCache;

		var root:String = Path.join([p, "hdlls"]);
		var staticDir:String = Path.join([root, "static", folder]);
		var dynamicDir:String = Path.join([root, "dynamic", folder]);

		var split:Bool = FileSystem.exists(Path.join([root, "static"])) || FileSystem.exists(Path.join([root, "dynamic"]));
		var legacyDir:String = Path.join([root, folder]);
		if (!split && FileSystem.exists(legacyDir)) {
			info('Old hdlls layout found ($legacyDir): treating it as dynamic. Move it to hdlls/dynamic/$folder.');
			dynamicDir = legacyDir;
		}

		var statics:Array<NativeLib> = [];
		var staticIds:Map<String, String> = new Map();
		for (f in listFilesWithExt(staticDir, staticLibExt())) {
			var id:String = nativeLibId(f, true);
			if (staticIds.exists(id))
				fail('Static libs "${staticIds.get(id)}" and "$f" in $staticDir are the same library ("$id"). Keep only one.');
			staticIds.set(id, f);
			statics.push({
				id: id,
				fileName: f,
				path: Path.join([staticDir, f]),
				isStatic: true
			});
		}

		var dynamics:Array<NativeLib> = [];
		var shadowed:Array<NativeLib> = [];
		for (f in listFilesWithExt(dynamicDir, "hdll")) {
			var id:String = nativeLibId(f, false);
			var lib:NativeLib = {
				id: id,
				fileName: f,
				path: Path.join([dynamicDir, f]),
				isStatic: false
			};
			if (staticIds.exists(id)) {
				info('"$id" exists as static (${staticIds.get(id)}) and dynamic ($f): linking the static one only.');
				shadowed.push(lib);
			} else {
				dynamics.push(lib);
			}
		}

		if (os == "WebAssembly" && dynamics.length > 0) {
			info('WebAssembly cannot load .hdll files: ignoring ${dynamics.map(l -> l.fileName).join(", ")}. Build them as static libraries (hdlls/static/$folder).');
			shadowed = shadowed.concat(dynamics);
			dynamics = [];
		}

		var sIds:String = statics.length > 0 ? statics.map(l -> l.id).join(", ") : "-";
		var dIds:String = dynamics.length > 0 ? dynamics.map(l -> l.id).join(", ") : "-";
		info('Native libs ($folder): static [$sIds] dynamic [$dIds]');

		nativeLibsCache = {
			statics: statics,
			dynamics: dynamics,
			shadowed: shadowed,
			staticDir: staticDir,
			dynamicDir: dynamicDir
		};
		return nativeLibsCache;
	}

	static function readStaticDeps(libs:Array<NativeLib>):Array<String> {
		var deps:Array<String> = [];
		var seen:Map<String, Bool> = new Map();

		for (lib in libs) {
			var depsPath:String = Path.withoutExtension(lib.path) + ".deps";
			if (!FileSystem.exists(depsPath)) {
				info('No ${Path.withoutDirectory(depsPath)} next to ${lib.fileName}: no extra system libraries will be linked for it.');
				continue;
			}
			for (line in File.getContent(depsPath).split("\n")) {
				var dep:String = line.trim();
				if (dep == "" || dep.startsWith("#"))
					continue;
				var key:String = os == "Windows" ? dep.toLowerCase() : dep;
				if (seen.exists(key))
					continue;
				seen.set(key, true);
				deps.push(dep);
			}
		}
		return deps;
	}

	static function addStaticDeps(buf:StringBuf, deps:Array<String>, alreadyLinked:Array<String>):Void {
		var skip:Map<String, Bool> = new Map();
		for (a in alreadyLinked)
			skip.set(os == "Windows" ? a.toLowerCase() : a, true);

		for (dep in deps) {
			if (skip.exists(os == "Windows" ? dep.toLowerCase() : dep))
				continue;
			if (dep.startsWith("-framework"))
				buf.add('        <flag value="$dep" />\n');
			else
				buf.add('        <lib name="$dep" />\n');
		}
	}

	static function exeFileName():String {
		var exeName:String = Context.definedValue("hl_exe_name");
		if (exeName == null)
			exeName = "output";
		return exeName + switch (os) {
			case "Windows": ".exe";
			case "WebAssembly": ".js";
			default: "";
		};
	}

	static function readHlcFiles(outputDir:String):Array<String> {
		var path:String = Path.join([outputDir, "hlc.json"]);
		if (!FileSystem.exists(path))
			return [];
		try {
			var text:String = File.getContent(path);
			var json:Dynamic = haxe.Json.parse(text.substr(text.indexOf("{")));
			var files:Array<String> = [for (f in (json.files : Array<Dynamic>)) (f : String)];
			return files.filter(f -> Path.extension(f) == "c" && FileSystem.exists(Path.join([outputDir, f])));
		} catch (e:Dynamic) {
			info('Could not read hlc.json ($e): falling back to the single-file build.');
			return [];
		}
	}

	static function collectHeaders(dir:String, rel:String, out:Array<String>):Void {
		for (item in FileSystem.readDirectory(dir)) {
			if (rel == "" && (item == "obj" || item == "build" || item.startsWith(".")))
				continue;
			var full:String = Path.join([dir, item]);
			var r:String = rel == "" ? item : rel + "/" + item;
			if (FileSystem.isDirectory(full))
				collectHeaders(full, r, out);
			else if (Path.extension(item) == "h")
				out.push(r);
		}
	}

	static function readIncludes(outputDir:String, rel:String):Array<String> {
		var out:Array<String> = [];
		var path:String = Path.join([outputDir, rel]);
		var text:String = "";
		try {
			var input = File.read(path, true);
			text = input.readString(Std.int(Math.min(16384, FileSystem.stat(path).size)));
			input.close();
		} catch (e:Dynamic) {}

		var re:EReg = ~/#[ \t]*include[ \t]*[<"]([^>"\r\n]+)[>"]/;
		var pos:Int = 0;
		while (pos < text.length && re.matchSub(text, pos)) {
			var inc:String = re.matched(1).replace("\\", "/");
			var mp = re.matchedPos();
			pos = mp.pos + mp.len;
			if (Path.extension(inc) == "h" && FileSystem.exists(Path.join([outputDir, inc])))
				out.push(inc);
		}
		return out;
	}

	static function headerClosure(outputDir:String, rel:String, direct:Map<String, Array<String>>, seen:Map<String, Bool>, out:Array<String>):Void {
		var incs:Array<String> = direct.get(rel);
		if (incs == null) {
			incs = readIncludes(outputDir, rel);
			direct.set(rel, incs);
		}
		for (h in incs) {
			if (seen.exists(h))
				continue;
			seen.set(h, true);
			out.push(h);
			headerClosure(outputDir, h, direct, seen, out);
		}
	}

	static function statLine(path:String):String {
		if (!FileSystem.exists(path))
			return path + ":-";
		var st = FileSystem.stat(path);
		return path + ":" + st.mtime.getTime() + ":" + st.size;
	}

	static function collectStamp(dir:String, rel:String, out:Array<String>):Void {
		var items:Array<String> = FileSystem.readDirectory(dir);
		items.sort(Reflect.compare);
		for (item in items) {
			if (rel == "" && (item == "obj" || item == "build" || item.startsWith(".") || item.startsWith("Build-")))
				continue;
			var full:String = Path.join([dir, item]);
			var r:String = rel == "" ? item : rel + "/" + item;
			if (FileSystem.isDirectory(full))
				collectStamp(full, r, out);
			else if (item.endsWith(".c") || item.endsWith(".h"))
				out.push(statLine(full));
		}
	}

	static function computeStamp(outputDir:String, xmlPath:String, nativeLibs:NativeLibs):String {
		var parts:Array<String> = [
			File.getContent(Path.join([outputDir, xmlPath])),
			os,
			arch,
			Std.string(Context.defined("hl_fast"))
		];
		collectStamp(outputDir, "", parts);
		parts.push(statLine(hlLibFile));
		parts.push(statLine(hlDllFile));
		for (l in nativeLibs.statics.concat(nativeLibs.dynamics)) {
			parts.push(statLine(l.path));
			parts.push(statLine(Path.withoutExtension(l.path) + ".deps"));
		}
		return haxe.crypto.Md5.encode(parts.join("\n"));
	}

	static function resolveCacheDir(outputDir:String):String {
		if (Context.defined("hl_no_cache"))
			return null;
		var dir:String = Context.definedValue("hl_cache");
		if (dir == null || dir == "1" || dir == "")
			dir = Path.join([outputDir, ".hlc_cache"]);
		if (!FileSystem.exists(dir))
			FileSystem.createDirectory(dir);
		return FileSystem.absolutePath(dir).replace("\\", "/");
	}

	static function generateBuildXml(p:String, outputDir:String, useCache:Bool = false):String {
		var exeName:String = Context.definedValue("hl_exe_name");
		if (exeName == null)
			exeName = "output";

		var split:Bool = !Context.defined("hl_unity");
		var cFiles:Array<String> = split ? readHlcFiles(outputDir) : [];
		if (cFiles.length > 1) {
			var sizes:Map<String, Int> = new Map();
			for (f in cFiles)
				sizes.set(f, FileSystem.stat(Path.join([outputDir, f])).size);
			cFiles.sort((a, b) -> sizes.get(b) - sizes.get(a));
		}
		if (cFiles.length == 0) {
			split = false;
			cFiles = [
				for (f in FileSystem.readDirectory(outputDir))
					if (Path.extension(f) == "c") f
			];
		}

		var nativeLibs:NativeLibs = resolveNativeLibs(p);
		var staticDeps:Array<String> = readStaticDeps(nativeLibs.statics);

		if (cFiles.length == 0)
			fail('No .c files found in $outputDir');

		var buf:StringBuf = new StringBuf();
		buf.add('<xml>\n');
		if (os == "WebAssembly") {
			buf.add('    <set name="emscripten" value="1" />\n');
		}
		buf.add('    <set name="BUILD_DIR" value="build/$folder" />\n\n');

		buf.add('    <files id="hlc">\n');
		buf.add('        <compilerflag value="-I$hlIncludeDir" />\n');
		buf.add('        <compilerflag value="-I." />\n');
		if (split)
			buf.add('        <compilerflag value="-DHL_MAKE" />\n');
		buf.add('        <compilerflag value="-std=c11" unless="windows" />\n');
		if (os == "WebAssembly") {
			buf.add('        <compilerflag value="-DHL_WEBASM" />\n');
			buf.add('        <compilerflag value="-D_GNU_SOURCE" />\n');
		}
		if (useCache) {
			buf.add('        <cache value="true" project="hlc" />\n');
			for (h in ["hl.h", "hlc.h", "hlc_main.c"])
				if (FileSystem.exists(Path.join([hlIncludeDir, h])))
					buf.add('        <depend name="${Path.join([hlIncludeDir, h])}" />\n');

			var direct:Map<String, Array<String>> = new Map();
			for (f in cFiles) {
				var deps:Array<String> = [];
				headerClosure(outputDir, f, direct, new Map(), deps);
				deps.sort(Reflect.compare);
				buf.add('        <file name="$f">\n');
				for (d in deps)
					buf.add('            <depend name="$d" />\n');
				buf.add('        </file>\n');
			}
		} else {
			for (f in cFiles)
				buf.add('        <file name="$f" />\n');
		}
		buf.add('    </files>\n\n');
		info((split ? 'Split build: ' : 'Single-file build: ')
			+ cFiles.length
			+ ' C file(s)'
			+ (useCache ? ', compile cache on' : ''));

		buf.add('    <target id="default" tool="linker" toolid="exe" output="$exeName" rebuild="true">\n');
		if (os == "Windows") {
			buf.add('        <flag value="/NOIMPLIB" />\n');
			if (nativeLibs.statics.length > 0) {
				buf.add('        <flag value="/IGNORE:4217,4286" />\n');
			}
			buf.add('        <ext value=".exe" />\n');
		} else if (os == "WebAssembly") {
			buf.add('        <ext value=".js" />\n');
			if (!Context.defined("hl_fast"))
				buf.add('        <flag value="-O3" />\n');
			buf.add('        <flag value="-s" />\n');
			buf.add('        <flag value="WASM=1" />\n');
			buf.add('        <flag value="-s" />\n');
			buf.add('        <flag value="ALLOW_MEMORY_GROWTH=1" />\n');
			buf.add('        <flag value="-s" />\n');
			buf.add('        <flag value="DEFAULT_TO_CXX=1" />\n');
		} else {
			buf.add('        <ext value="" />\n');
		}
		buf.add("        <outdir name=\"${BUILD_DIR}\" />\n");
		buf.add('        <files id="hlc" />\n\n');

		if (os == "Windows") {
			for (hdll in nativeLibs.dynamics) {
				buf.add('        <flag value="/DELAYLOAD:${hdll.fileName}" />\n');
				var libPath = ensureImportLib(hdll.path);
				buf.add('        <lib name="$libPath" />\n');
			}
			for (sl in nativeLibs.statics)
				buf.add('        <lib name="${sl.path}" />\n');
			buf.add('        <lib name="delayimp.lib" />\n');
			buf.add('        <lib name="$hlLibFile" />\n');
			buf.add('        <lib name="winmm.lib" />\n');
			buf.add('        <lib name="user32.lib" />\n');
			buf.add('        <lib name="gdi32.lib" />\n');
			buf.add('        <lib name="shell32.lib" />\n');
			buf.add('        <lib name="opengl32.lib" />\n');
			addStaticDeps(buf, staticDeps, [
				"delayimp.lib",
				"winmm.lib",
				"user32.lib",
				"gdi32.lib",
				"shell32.lib",
				"opengl32.lib"
			]);
		} else if (os == "WebAssembly") {
			for (sl in nativeLibs.statics)
				buf.add('        <lib name="${sl.path}" />\n');
			buf.add('        <lib name="$hlLibFile" />\n');
			addStaticDeps(buf, staticDeps, []);
		} else {
			if (os == "Mac") {
				buf.add('        <lib name="-Wl,-force_load,$hlLibFile" />\n');
				buf.add('        <lib name="-Wl,-export_dynamic" />\n');
			} else {
				buf.add('        <lib name="-Wl,--whole-archive" />\n');
				buf.add('        <lib name="$hlLibFile" />\n');
				buf.add('        <lib name="-Wl,--no-whole-archive" />\n');
				buf.add('        <lib name="-rdynamic" />\n');
			}
			for (sl in nativeLibs.statics)
				buf.add('        <lib name="${sl.path}" />\n');
			addStaticDeps(buf, staticDeps, [
				"-lm",
				"-lpthread",
				"-ldl",
				"-llog",
				"-framework Cocoa",
				"-framework OpenGL",
				"-framework IOKit"
			]);

			buf.add('        <lib name="-lm" />\n');
			buf.add('        <lib name="-lpthread" if="linux" />\n');
			buf.add('		<lib name="-luv" if="linux" />\n');
			buf.add('        <lib name="-ldl" if="linux" />\n');
			buf.add('        <lib name="-llog" if="android" />\n');

			if (os == "Mac") {
				buf.add('        <flag value="-framework Cocoa" />\n');
				buf.add('        <flag value="-framework OpenGL" />\n');
				buf.add('        <flag value="-framework IOKit" />\n');
			}

			if (nativeLibs.dynamics.length > 0) {
				buf.add('        <lib name="-Wl,-rpath,\'$$ORIGIN\'" if="linux" />\n');
				for (hdll in nativeLibs.dynamics) {
					failIfRuntimeEmbeddedUnix(hdll.path);
					buf.add('        <lib name="${hdll.path}" />\n');
				}
			}
		}

		buf.add('    </target>\n');
		buf.add('</xml>\n');

		var xmlFileName:String = 'Build-$folder.xml';
		var xmlPath:String = Path.join([outputDir, xmlFileName]);
		File.saveContent(xmlPath, buf.toString());
		info('Build file written to $xmlPath');

		return xmlFileName;
	}

	static var msvcToolsDir:String = null;

	static function getMsvcToolsDir():String {
		if (msvcToolsDir != null)
			return msvcToolsDir;

		var vswherePath:String = Path.join([
			Sys.getEnv("ProgramFiles(x86)"),
			"Microsoft Visual Studio",
			"Installer",
			"vswhere.exe"
		]);

		if (!FileSystem.exists(vswherePath))
			fail('vswhere.exe not found at $vswherePath. Do you have Visual Studio Build Tools installed?');

		var proc:Process = new Process(vswherePath, [
			"-latest",
			"-products",
			"*",
			"-requires",
			"Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
			"-property",
			"installationPath"
		]);
		var vsPath:String = StringTools.trim(proc.stdout.readAll().toString());
		proc.close();

		if (vsPath == "")
			fail('vswhere could not find a Visual Studio installation with the C++ Build Tools. Install the "Desktop development with C++" workload.');

		var versionFile:String = Path.join([vsPath, "VC", "Auxiliary", "Build", "Microsoft.VCToolsVersion.default.txt"]);
		if (!FileSystem.exists(versionFile))
			fail('File not found: $versionFile');

		var version:String = StringTools.trim(File.getContent(versionFile));
		var hostArch:String = "Hostx64";
		var targetArch:String = (arch == "32") ? "x86" : "x64";

		var toolsDir:String = Path.join([vsPath, "VC", "Tools", "MSVC", version, "bin", hostArch, targetArch]);
		if (!FileSystem.exists(toolsDir))
			fail('MSVC tools directory not found: $toolsDir');

		msvcToolsDir = toolsDir;
		return toolsDir;
	}

	static function runTool(exeName:String, args:Array<String>):{code:Int, output:String} {
		var exePath:String = Path.join([getMsvcToolsDir(), exeName]);
		if (!FileSystem.exists(exePath))
			fail('Not found: $exePath');

		var proc:Process;
		try {
			proc = new Process(exePath, args);
		} catch (e:Dynamic) {
			fail('Could not run $exePath: $e');
			return null;
		}
		var output:String = proc.stdout.readAll().toString() + proc.stderr.readAll().toString();
		var code:Int = proc.exitCode();
		proc.close();
		return {code: code, output: output};
	}

	static var hlLibSymbolsCache:Map<String, Bool> = null;

	static function getHlLibSymbols():Map<String, Bool> {
		if (hlLibSymbolsCache != null)
			return hlLibSymbolsCache;

		var result:Map<String, Bool> = new Map();

		if (!FileSystem.exists(hlLibFile)) {
			hlLibSymbolsCache = result;
			return result;
		}

		var dump = runTool("dumpbin.exe", ["/linkermember:1", hlLibFile]);
		if (dump.code != 0)
			fail('dumpbin /linkermember failed on $hlLibFile:\n${dump.output}');

		for (line in dump.output.split("\n")) {
			var trimmed:String = StringTools.trim(line);
			var parts:Array<String> = trimmed.split(" ").filter(p -> p != "");
			if (parts.length == 2 && ~/^[0-9A-Fa-f]+$/.match(parts[0])) {
				result.set(parts[1], true);
			}
		}

		hlLibSymbolsCache = result;
		return result;
	}

	static function readExports(binPath:String):Array<String> {
		var dump = runTool("dumpbin.exe", ["/exports", binPath]);
		if (dump.code != 0)
			fail('dumpbin failed on $binPath:\n${dump.output}');

		var exports:Array<String> = [];
		for (line in dump.output.split("\n")) {
			var trimmed:String = StringTools.trim(line);
			var parts:Array<String> = trimmed.split(" ").filter(p -> p != "");
			if (parts.length >= 4 && ~/^[0-9]+$/.match(parts[0]) && ~/^[0-9A-Fa-f]+$/.match(parts[2]))
				exports.push(parts[parts.length - 1]);
		}
		return exports;
	}

	static function writeImportLib(binFileName:String, exports:Array<String>, defPath:String, libPath:String):Void {
		if (exports.length == 0)
			fail('No exported symbols found for $binFileName');

		var defBuf:StringBuf = new StringBuf();
		defBuf.add('LIBRARY $binFileName\n');
		defBuf.add('EXPORTS\n');
		for (sym in exports)
			defBuf.add('    $sym\n');
		File.saveContent(defPath, defBuf.toString());

		var machine:String = (arch == "32") ? "X86" : "X64";
		var lib = runTool("lib.exe", ['/def:$defPath', '/out:$libPath', '/machine:$machine']);

		if (lib.code != 0 || !FileSystem.exists(libPath))
			fail('Could not generate $libPath with lib.exe:\n${lib.output}');

		info('Import lib generated: $libPath');
	}

	static function failIfRuntimeEmbedded(hdllFileName:String, exportedSymbols:Array<String>):Void {
		if (Context.defined("hl_allow_embedded_runtime"))
			return;

		if (exportedSymbols.indexOf("hl_global_init") >= 0
			|| exportedSymbols.indexOf("hl_setup") >= 0
			|| exportedSymbols.indexOf("hl_dyn_call") >= 0) {
			fail('$hdllFileName contains its own copy of the HashLink runtime (it exports hl_global_init / hl_setup / hl_dyn_call).\n'
				+ '  Two runtimes in one process => callbacks and GC calls crash.\n'
				+ '  Rebuild the hdll with the updated haxelib (it must import libhl, not embed it),\n'
				+ '  or pass -D hl_allow_embedded_runtime if you really know what you are doing.');
		}
	}

	static function failIfRuntimeEmbeddedUnix(hdllPath:String):Void {
		if (Context.defined("hl_allow_embedded_runtime"))
			return;

		var proc:Process;
		try {
			proc = new Process("nm", os == "Mac" ? ["-gU", hdllPath] : ["-D", "--defined-only", hdllPath]);
		} catch (e:Dynamic) {
			return;
		}
		var out:String = proc.stdout.readAll().toString();
		proc.exitCode();
		proc.close();

		var embedded = ~/[ ]_?hl_global_init\b/.match(out) || ~/[ ]_?hl_dyn_call\b/.match(out);
		if (embedded) {
			fail('${Path.withoutDirectory(hdllPath)} contains its own copy of the HashLink runtime.\n'
				+ '  It only appears to work on Linux through symbol interposition and breaks on macOS/Windows.\n'
				+ '  Rebuild it with the updated haxelib, or pass -D hl_allow_embedded_runtime to skip this check.');
		}
	}

	static function ensureImportLib(hdllPath:String):String {
		var dir:String = Path.directory(hdllPath);
		var name:String = Path.withoutExtension(Path.withoutDirectory(hdllPath));
		var libPath:String = Path.join([dir, '$name.lib']);
		var defPath:String = Path.join([dir, '$name.def']);

		var hdllFileName:String = Path.withoutDirectory(hdllPath);
		var allExports:Array<String> = readExports(hdllPath);
		failIfRuntimeEmbedded(hdllFileName, allExports);

		if (FileSystem.exists(libPath)) {
			var libTime = FileSystem.stat(libPath).mtime.getTime();
			var hdllTime = FileSystem.stat(hdllPath).mtime.getTime();
			if (libTime >= hdllTime) {
				info('Reusing existing import lib: $libPath');
				return libPath;
			}
		}

		info('Generating import lib for $name.hdll...');

		var hlSymbols:Map<String, Bool> = getHlLibSymbols();
		var exports:Array<String> = [];
		for (sym in allExports) {
			if (hlSymbols.exists(sym)) {
				info('Skipping runtime symbol from $name.hdll export: $sym');
				continue;
			}
			exports.push(sym);
		}

		writeImportLib(hdllFileName, exports, defPath, libPath);
		return libPath;
	}

	static function copyHdlls(projectPath:String, outputDir:String):Void {
		var nativeLibs:NativeLibs = resolveNativeLibs(projectPath);
		var hdllsDir:String = nativeLibs.dynamicDir;
		var targetDir:String = Path.join([outputDir, "build", folder]);

		if (os == "Windows" && FileSystem.exists(hlDllFile)) {
			if (!FileSystem.exists(targetDir))
				FileSystem.createDirectory(targetDir);
			File.copy(hlDllFile, Path.join([targetDir, "libhl.dll"]));
			info('Copied runtime: libhl.dll -> $targetDir');
		}

		if (FileSystem.exists(hdllsDir)) {
			var shadowed:Array<String> = nativeLibs.shadowed.map(l -> l.fileName);
			if (!FileSystem.exists(targetDir)) {
				FileSystem.createDirectory(targetDir);
			}
			for (file in FileSystem.readDirectory(hdllsDir)) {
				if (shadowed.indexOf(file) >= 0)
					continue;
				if (file.endsWith(".hdll") || file.endsWith(".dll") || file.endsWith(".so") || file.endsWith(".dylib") || file.endsWith(".wasm")
					|| file.endsWith(".js")) {
					var srcPath = Path.join([hdllsDir, file]);
					var destPath = Path.join([targetDir, file]);

					File.copy(srcPath, destPath);
					info('Copied plugin: $file -> $destPath');
				}
			}
		}
	}

	static function compileBuildXml(p:String, xmlPath:String, ?workingDir:String, ?cacheDir:String):Void {
		var oldCwd:String = Sys.getCwd();

		if (workingDir != null)
			Sys.setCwd(workingDir);

		var objDir:String = "obj";
		if (FileSystem.exists(objDir)) {
			try {
				deleteDirectoryRecursive(objDir);
			} catch (e:Dynamic) {
				info('Could not delete the obj folder: $e');
			}
		}

		var exePath:String = Path.join(["build", folder, exeFileName()]);

		if (FileSystem.exists(exePath)) {
			try {
				FileSystem.deleteFile(exePath);
			} catch (e:Dynamic) {}
		}

		var args:Array<String> = [xmlPath];
		if (os == "WebAssembly") {
			args.push("-Demscripten");

			if (Sys.systemName() == "Windows")
				args.push("-Dnostrip");
		} else {
			args.push("-D" + os.toLowerCase());
		}

		switch (arch) {
			case "64":
				args.push("-DHXCPP_M64");
			case "32":
				args.push("-DHXCPP_M32");
			case "Arm64":
				args.push("-DHXCPP_ARM64");
			case "Arm7":
				args.push("-DHXCPP_ARM7");
		}

		args.push("-Dclean");

		if (cacheDir != null)
			args.push("-DHXCPP_COMPILE_CACHE=" + cacheDir);

		if (Context.defined("hl_fast") && xmlPath != "BuildHashlink.xml") {
			if (os == "WebAssembly") {
				args.push("-DHXCPP_OPTIM_LEVEL=-O0");
				args.push("-DHXCPP_LINK_OPTIM_LEVEL=-O0");
			} else {
				args.push("-Ddebug");
				args.push("-DHXCPP_NO_DEBUG_LINK");
			}
		}

		var parts:Array<String> = ["haxelib", "run", "hxcpp"];
		for (a in args)
			parts.push(quoteIfNeeded(a));

		var cmd:String = parts.join(" ");
		info('Invoking hxcpp in working directory: ${Sys.getCwd()}...');

		var code:Int = Sys.command(cmd);

		if (workingDir != null)
			Sys.setCwd(oldCwd);

		if (code != 0)
			fail('hxcpp exited with code $code');
	}

	static function deleteDirectoryRecursive(dir:String):Void {
		if (FileSystem.exists(dir)) {
			for (item in FileSystem.readDirectory(dir)) {
				var path = Path.join([dir, item]);
				if (FileSystem.isDirectory(path)) {
					deleteDirectoryRecursive(path);
				} else {
					FileSystem.deleteFile(path);
				}
			}
			FileSystem.deleteDirectory(dir);
		}
	}

	static function quoteIfNeeded(s:String):String {
		if (s.indexOf(" ") >= 0 || s.indexOf("\t") >= 0)
			return '"' + s + '"';
		return s;
	}

	static function getHaxelibPath():String {
		var proc:Process = new Process("haxelib", ["path", "hl_compile"]);
		var lines:Array<String> = proc.stdout.readAll().toString().split("\n");
		proc.close();
		return Path.normalize(StringTools.trim(lines[1]));
	}

	static inline function info(msg:String):Void {
		Sys.println('[$TAG] $msg');
	}

	static function fail(msg:String):Void {
		Sys.println('[$TAG] Error: $msg');
		Sys.exit(1);
	}
}
#end
