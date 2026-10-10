package hlcompiler;

#if macro
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import haxe.macro.Context;
import haxe.macro.Compiler;
import hlcompiler.HlBytecode;

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
	var dynamicDirs:Array<String>;
}

typedef HdllUnit = {
	var name:String;
	var filesXml:String;
	var targetXml:String;
	var globalsXml:String;
	var stamp:Array<String>;
	var includeDirs:Array<String>;
}

typedef HlModule = {
	var name:String;
	var dir:String;
	var file:String;
	var root:Xml;
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
		Compiler.registerCustomMetadata({metadata: ":injectNativeFunction", doc: "Injects a native function to the final c++ compilation"});

		nativeLibsCache = null;
		modulesCache = null;
		pkgCache = new Map();
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
		var output:String = Compiler.getOutput();
		if (output == null || output == "")
			return;

		var old:String = Sys.getCwd();

		if (!FileSystem.exists(Path.join([hlIncludeDir, "hl.h"])))
			fail('HashLink sources not found in $hlIncludeDir.\n'
				+ '  The hashlink/ folder is a git submodule: run "git submodule update --init --recursive" in $haxelibPath\n'
				+ '  (or "haxelib run hl_compile doctor" to check everything).');

		var vm:Bool = isVmOutput();
		if (vm && os == "WebAssembly")
			fail('VM mode (--hl <file>.hl) is not available for WebAssembly: the HashLink VM needs a JIT. Use --hl <file>.c instead.');
		if (vm && arch != "64")
			fail('VM mode (--hl <file>.hl) needs x86-64: the HashLink JIT does not support this architecture. Use --hl <file>.c instead.');

		getModules();

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

		if (vm) {
			buildVm(old, outputDir);
			info('Build completed successfully.');
			return;
		}

		var cacheDir:String = resolveCacheDir(outputDir);
		var xmlPath:String = generateBuildXml(old, outputDir, cacheDir != null);

		var stampFile:String = Path.join([outputDir, ".hlc_stamp"]);
		var exeFile:String = Path.join([outputDir, "build", folder, exeFileName()]);
		var stamp:String = computeStamp(outputDir, xmlPath, resolveNativeLibs(old), old);

		if (!Context.defined("hl_force") && FileSystem.exists(exeFile) && FileSystem.exists(stampFile) && File.getContent(stampFile) == stamp) {
			info('Up to date: nothing changed since the last build, native build skipped (-D hl_force to rebuild).');
		} else {
			if (FileSystem.exists(stampFile))
				FileSystem.deleteFile(stampFile);
			compileBuildXml(old, xmlPath, outputDir, cacheDir);
			File.saveContent(stampFile, stamp);
		}

		copyHdlls(old, outputDir);
		copyModuleFiles(outputDir);
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
	static var modulesCache:Array<HlModule> = null;

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

		var roots:Array<{root:String, owner:String}> = [{root: Path.join([p, "hdlls"]), owner: "project"}];
		for (r in moduleHdllRoots())
			roots.push(r);

		var rootDirs:Array<{staticDir:String, dynamicDir:String, owner:String}> = [];
		for (r in roots) {
			var staticDir:String = Path.join([r.root, "static", folder]);
			var dynamicDir:String = Path.join([r.root, "dynamic", folder]);

			var split:Bool = FileSystem.exists(Path.join([r.root, "static"])) || FileSystem.exists(Path.join([r.root, "dynamic"]));
			var legacyDir:String = Path.join([r.root, folder]);
			if (!split && FileSystem.exists(legacyDir)) {
				info('Old hdlls layout found ($legacyDir): treating it as dynamic. Move it to ${Path.join([r.root, "dynamic", folder])}.');
				dynamicDir = legacyDir;
			}
			rootDirs.push({staticDir: staticDir, dynamicDir: dynamicDir, owner: r.owner});
		}

		var statics:Array<NativeLib> = [];
		var staticIds:Map<String, String> = new Map();
		var staticFiles:Map<String, String> = new Map();
		for (rd in rootDirs) {
			var local:Map<String, String> = new Map();
			for (f in listFilesWithExt(rd.staticDir, staticLibExt())) {
				var id:String = nativeLibId(f, true);
				if (local.exists(id))
					fail('Static libs "${local.get(id)}" and "$f" in ${rd.staticDir} are the same library ("$id"). Keep only one.');
				local.set(id, f);
				if (staticIds.exists(id)) {
					info('Static "$id" ($f, ${rd.owner}) ignored: already provided by ${staticIds.get(id)}.');
					continue;
				}
				staticIds.set(id, rd.owner);
				staticFiles.set(id, f);
				statics.push({
					id: id,
					fileName: f,
					path: Path.join([rd.staticDir, f]),
					isStatic: true
				});
			}
		}

		var dynamics:Array<NativeLib> = [];
		var shadowed:Array<NativeLib> = [];
		var dynamicIds:Map<String, String> = new Map();
		var dynamicDirs:Array<String> = [];
		for (rd in rootDirs) {
			if (FileSystem.exists(rd.dynamicDir) && FileSystem.isDirectory(rd.dynamicDir))
				dynamicDirs.push(rd.dynamicDir);
			for (f in listFilesWithExt(rd.dynamicDir, "hdll")) {
				var id:String = nativeLibId(f, false);
				var lib:NativeLib = {
					id: id,
					fileName: f,
					path: Path.join([rd.dynamicDir, f]),
					isStatic: false
				};
				if (staticIds.exists(id)) {
					info('"$id" exists as static (${staticFiles.get(id)}) and dynamic ($f): linking the static one only.');
					shadowed.push(lib);
				} else if (dynamicIds.exists(id)) {
					info('Dynamic "$id" ($f, ${rd.owner}) ignored: already provided by ${dynamicIds.get(id)}.');
					shadowed.push(lib);
				} else {
					dynamicIds.set(id, rd.owner);
					dynamics.push(lib);
				}
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
			dynamicDirs: dynamicDirs
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
			exeName = os == "WebAssembly" ? "index" : "output";
		return exeName + switch (os) {
			case "Windows": ".exe";
			case "WebAssembly": ".html";
			default: "";
		}
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

	static function collectStampNatives(dir:String, rel:String, out:Array<String>):Void {
		var items:Array<String> = FileSystem.readDirectory(dir);
		items.sort(Reflect.compare);
		for (item in items) {
			if (item.startsWith("."))
				continue;
			var full:String = Path.join([dir, item]);
			var r:String = rel == "" ? item : rel + "/" + item;
			if (FileSystem.isDirectory(full)) {
				collectStampNatives(full, r, out);
			} else {
				var ext:String = Path.extension(item).toLowerCase();
				if (ext == "c" || ext == "cpp" || ext == "c++" || ext == "cc" || ext == "h" || ext == "hpp")
					out.push(statLine(full));
			}
		}
	}

	static inline function nativeStaticLibExt():String {
		return os == "Windows" ? "lib" : "a";
	}

	static function collectNativeStaticLibs(dir:String):Array<String> {
		var out:Array<String> = [];
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return out;

		var ext:String = nativeStaticLibExt();
		for (f in FileSystem.readDirectory(dir)) {
			var full:String = Path.join([dir, f]);
			if (FileSystem.isDirectory(full)) {
				for (sub in collectNativeStaticLibs(full))
					out.push(sub);
			} else if (Path.extension(f).toLowerCase() == ext) {
				out.push(full);
			}
		}
		out.sort(Reflect.compare);
		return out;
	}

	static function computeStamp(outputDir:String, xmlPath:String, nativeLibs:NativeLibs, projectPath:String):String {
		var parts:Array<String> = [
			File.getContent(Path.join([outputDir, xmlPath])),
			os,
			arch,
			Std.string(Context.defined("hl_fast"))
		];
		collectStamp(outputDir, "", parts);

		var nativesDir:String = Path.join([projectPath, "natives"]);
		if (FileSystem.exists(nativesDir))
			collectStampNatives(nativesDir, "", parts);

		for (m in getModules())
			collectModuleStamp(m, parts);

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
			dir = Sys.getEnv("HL_COMPILE_CACHE");
		if (dir == null || dir == "")
			dir = Path.join([outputDir, ".hlc_cache"]);
		ensureDir(FileSystem.absolutePath(dir));
		return FileSystem.absolutePath(dir).replace("\\", "/");
	}

	static function generateBuildXml(p:String, outputDir:String, useCache:Bool = false):String {
		var exeName:String = Context.definedValue("hl_exe_name");
		if (exeName == null)
			exeName = os == "WebAssembly" ? "index" : "output";

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
		buf.add('    <set name="BUILD_DIR" value="build/$folder" />\n');
		buf.add('    <set name="HL_FOLDER" value="$folder" />\n');
		buf.add('    <set name="HL_INCLUDE" value="$hlIncludeDir" />\n');
		addModuleGlobals(buf);

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
		addUserCFlags(buf);
		addModuleFiles(buf, "hlc");
		buf.add('    </files>\n\n');

		buf.add('    <files id="natives">\n');
		buf.add('        <compilerflag value="-I$hlIncludeDir" />\n');
		buf.add('        <compilerflag value="-DHL_COMPILE_HLC" />\n');
		addUserCFlags(buf);

		var natives_path:String = Path.join([p, "natives"]);
		if (FileSystem.exists(natives_path)) {
			buf.add('        <compilerflag value="-I$natives_path" />\n');
			addFilesRecursively(natives_path, buf);
		}

		var injections_path:String = Path.join([p, outputDir, "injections"]);
		if (FileSystem.exists(injections_path)) {
			buf.add('        <compilerflag value="-I$injections_path" />\n');
			addFilesRecursively(injections_path, buf);
		}
		if (useCache) {
			buf.add('        <cache value="true" project="natives" />\n');
			var headerDirs:Array<String> = [natives_path, injections_path];
			for (m in getModules())
				headerDirs = headerDirs.concat(moduleIncludeDirs(m));
			addHeaderDepends(buf, headerDirs);
		}
		addModuleFiles(buf, "natives");
		buf.add('    </files>\n\n');

		var nativeStaticLibs:Array<String> = collectNativeStaticLibs(natives_path);
		if (nativeStaticLibs.length > 0) {
			info('Linking user static libs from natives/: ${nativeStaticLibs.length} file(s)');
		}

		info((split ? 'Split build: ' : 'Single-file build: ')
			+ cFiles.length
			+ ' C file(s)'
			+ (useCache ? ', compile cache on' : ''));

		buf.add('    <target id="default" tool="linker" toolid="exe" output="$exeName" rebuild="true">\n');
		if (os == "Windows") {
			buf.add('        <flag value="/NOIMPLIB" />\n');
			buf.add('        <flag value="/IGNORE:4217,4286" />\n');
			buf.add('        <ext value=".exe" />\n');
		} else if (os == "WebAssembly") {
			buf.add('        <ext value=".html" />\n');
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
		addUserLinkFlags(buf);
		buf.add('        <files id="hlc" />\n');
		buf.add('        <files id="natives" />\n\n');

		for (nl in nativeStaticLibs)
			buf.add('        <lib name="$nl" />\n');

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
			buf.add('        <lib name="setupapi.lib" />\n');
			buf.add('        <lib name="version.lib" />\n');
			buf.add('        <lib name="imm32.lib" />\n');
			addStaticDeps(buf, staticDeps, [
				"delayimp.lib",
				"winmm.lib",
				"user32.lib",
				"gdi32.lib",
				"shell32.lib",
				"opengl32.lib"
			]);
			addModuleTarget(buf);
		} else if (os == "WebAssembly") {
			for (sl in nativeLibs.statics)
				buf.add('        <lib name="${sl.path}" />\n');
			addModuleTarget(buf);
			buf.add('        <lib name="$hlLibFile" />\n');
			if (Context.defined("hl_sdl3")) {
				buf.add('		 <flag value="-s"/>\n');
				buf.add('		 <flag value="USE_SDL=3"/>\n');
			}
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
			addModuleTarget(buf);

			buf.add('        <lib name="-lm" />\n');
			buf.add('        <lib name="-lpthread" if="linux" />\n');
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
		var targetDir:String = Path.join([outputDir, "build", folder]);

		if (os == "Windows" && FileSystem.exists(hlDllFile)) {
			ensureDir(targetDir);
			if (copyIfChanged(hlDllFile, Path.join([targetDir, "libhl.dll"])))
				info('Copied runtime: libhl.dll -> $targetDir');
		}

		var shadowed:Array<String> = nativeLibs.shadowed.map(l -> l.path);
		for (hdllsDir in nativeLibs.dynamicDirs) {
			ensureDir(targetDir);
			for (file in FileSystem.readDirectory(hdllsDir)) {
				var srcPath:String = Path.join([hdllsDir, file]);
				if (shadowed.indexOf(srcPath) >= 0)
					continue;
				if (file.endsWith(".hdll") || file.endsWith(".dll") || file.endsWith(".so") || file.endsWith(".dylib") || file.endsWith(".wasm")
					|| file.endsWith(".js")) {
					var destPath:String = Path.join([targetDir, file]);

					if (copyIfChanged(srcPath, destPath))
						info('Copied plugin: $file -> $destPath');
				}
			}
		}
	}

	static function hxcppArgs(xmlPath:String, cacheDir:String, target:String):Array<String> {
		var args:Array<String> = [xmlPath];
		if (target != null)
			args.push(target);
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
		return args;
	}

	static function compileBuildXml(p:String, xmlPath:String, ?workingDir:String, ?cacheDir:String, ?target:String):Void {
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

		var args:Array<String> = hxcppArgs(xmlPath, cacheDir, target);

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

	static function addFilesRecursively(dirPath:String, buf:StringBuf):Void {
		if (FileSystem.exists(dirPath) && FileSystem.isDirectory(dirPath)) {
			for (file in FileSystem.readDirectory(dirPath)) {
				var fullPath:String = Path.join([dirPath, file]);

				if (FileSystem.isDirectory(fullPath)) {
					addFilesRecursively(fullPath, buf);
				} else {
					var ext:String = Path.extension(fullPath);
					if (ext == "c" || ext == "c++" || ext == "cpp") {
						buf.add('        <file name="${fullPath}"/>\n');
					}
				}
			}
		}
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

	static inline var MODULE_FILE:String = "hl_module.xml";

	static var moduleLocalTags:Array<String> = ["files", "target", "copy", "hdlls", "requires", "pkgconfig"];

	static var moduleGlobalTags:Array<String> = ["set", "unset", "section", "error", "echo"];

	static function getModules():Array<HlModule> {
		if (modulesCache != null)
			return modulesCache;

		var found:Array<HlModule> = [];
		var seen:Map<String, Bool> = new Map();

		function addFile(file:String):Void {
			if (file == null || seen.exists(file))
				return;
			seen.set(file, true);
			found.push(loadModule(file));
		}

		for (cp in Context.getClassPath())
			addFile(findModuleFile(absDir(cp)));

		var projectFile:String = Path.join([absDir(""), MODULE_FILE]);
		if (FileSystem.exists(projectFile))
			addFile(projectFile);

		checkModuleRequirements(found);
		if (found.length > 0)
			info('Modules: ' + found.map(m -> m.name).join(", "));

		modulesCache = found;
		return modulesCache;
	}

	static function absDir(p:String):String {
		if (p == "")
			p = "./";
		return Path.removeTrailingSlashes(Path.normalize(FileSystem.absolutePath(p)));
	}

	static function findModuleFile(startDir:String):String {
		var d:String = startDir;
		for (i in 0...3) {
			var f:String = Path.join([d, MODULE_FILE]);
			if (FileSystem.exists(f) && !FileSystem.isDirectory(f))
				return f;
			var parent:String = Path.directory(d);
			if (parent == "" || parent == d)
				break;
			d = parent;
		}
		return null;
	}

	static function defaultModuleName(dir:String):String {
		var n:String = Path.withoutDirectory(dir);
		if (~/^[0-9]+([,.][0-9]+)*$/.match(n) || n == "git" || n == "dev")
			n = Path.withoutDirectory(Path.directory(dir));
		return n;
	}

	static function moduleVar(m:HlModule):String {
		return ~/[^A-Za-z0-9_]/g.replace(m.name, "_").toUpperCase();
	}

	static function loadModule(file:String):HlModule {
		var dir:String = Path.directory(file);
		var root:Xml = null;
		try {
			root = Xml.parse(File.getContent(file)).firstElement();
		} catch (e:Dynamic) {
			fail('Could not parse $file: $e');
		}
		if (root == null || root.nodeName != "hlmodule")
			fail('$file: the root element must be <hlmodule>.');

		var name:String = root.get("name");
		if (name == null || name.trim() == "")
			name = defaultModuleName(dir);

		var m:HlModule = {
			name: name.trim(),
			dir: dir,
			file: file,
			root: root
		};
		prepareXml(root, m);
		return m;
	}

	static function substVars(s:String, m:HlModule):String {
		return s.replace("${HLMODULE_DIR}", m.dir)
			.replace("${HLMODULE_NAME}", m.name)
			.replace("${HL_FOLDER}", folder)
			.replace("${HL_INCLUDE}", hlIncludeDir);
	}

	static function prepareXml(x:Xml, m:HlModule):Void {
		for (e in x.elements()) {
			var attrs:Array<String> = [for (n in e.attributes()) n];
			for (a in attrs)
				e.set(a, substVars(e.get(a), m));
			if (e.nodeName == "file" || e.nodeName == "depend" || e.nodeName == "lib")
				absolutizeName(e, m);
			prepareXml(e, m);
		}
	}

	static function absolutizeName(e:Xml, m:HlModule):Void {
		var n:String = e.get("name");
		if (n == null || n == "" || n.startsWith("-") || n.startsWith("${") || Path.isAbsolute(n))
			return;
		var full:String = Path.join([m.dir, n]);
		if (n.indexOf("/") >= 0 || n.indexOf("\\") >= 0 || FileSystem.exists(full))
			e.set("name", Path.normalize(full));
	}

	static function resolveModulePath(m:HlModule, p:String):String {
		return Path.removeTrailingSlashes(Path.normalize(Path.isAbsolute(p) ? p : Path.join([m.dir, p])));
	}

	static function conditionMet(e:Xml):Bool {
		var cond:String = e.get("if");
		if (cond != null && !evalCondition(cond))
			return false;
		var neg:String = e.get("unless");
		if (neg != null && evalCondition(neg))
			return false;
		return true;
	}

	static function evalCondition(expr:String):Bool {
		for (orPart in expr.split("||")) {
			var all:Bool = true;
			for (andPart in orPart.split("&&")) {
				if (!tokenHolds(andPart.trim())) {
					all = false;
					break;
				}
			}
			if (all)
				return true;
		}
		return false;
	}

	static function tokenHolds(token:String):Bool {
		var negate:Bool = token.startsWith("!");
		if (negate)
			token = token.substr(1).trim();
		var holds:Bool = switch (token.toLowerCase()) {
			case "windows": os == "Windows";
			case "linux": os == "Linux";
			case "mac" | "macos": os == "Mac";
			case "android": os == "Android";
			case "ios" | "iphone": os == "iPhone";
			case "emscripten" | "webassembly" | "wasm": os == "WebAssembly";
			case "x64" | "m64": arch == "64";
			case "x86" | "m32": arch == "32";
			case "arm64": arch == "Arm64";
			case "arm7": arch == "Arm7";
			default: Context.defined(token);
		};
		return negate ? !holds : holds;
	}

	static var pkgCache:Map<String, {cflags:Array<String>, libs:Array<String>}> = new Map();

	static function libVersion():String {
		try {
			var j:Dynamic = haxe.Json.parse(File.getContent(Path.join([haxelibPath, "haxelib.json"])));
			return Std.string(j.version);
		} catch (e:Dynamic) {
			return "0.0.0";
		}
	}

	static function compareVersions(a:String, b:String):Int {
		var pa:Array<String> = a.split(".");
		var pb:Array<String> = b.split(".");
		for (i in 0...Std.int(Math.max(pa.length, pb.length))) {
			var x:Int = i < pa.length ? Std.parseInt(pa[i]) : 0;
			var y:Int = i < pb.length ? Std.parseInt(pb[i]) : 0;
			if (x == null)
				x = 0;
			if (y == null)
				y = 0;
			if (x != y)
				return x < y ? -1 : 1;
		}
		return 0;
	}

	static function checkModuleRequirements(modules:Array<HlModule>):Void {
		var names:Map<String, Bool> = new Map();
		for (m in modules)
			names.set(m.name, true);

		for (m in modules) {
			for (r in m.root.elements()) {
				if (r.nodeName != "requires" || !conditionMet(r))
					continue;
				var mod:String = r.get("module");
				if (mod != null && !names.exists(mod))
					fail('Module "${m.name}" (${m.file}) requires the module "$mod", which was not found.\n  Add the library that provides it (--library ...).');
				var def:String = r.get("define");
				if (def != null && !Context.defined(def))
					fail('Module "${m.name}" (${m.file}) requires -D $def.');
				var v:String = r.get("hl_compile");
				if (v != null && compareVersions(libVersion(), v) < 0)
					fail('Module "${m.name}" (${m.file}) requires hl_compile $v or newer (this is ${libVersion()}).');
			}
		}
	}

	static function pkgConfig(name:String):{cflags:Array<String>, libs:Array<String>} {
		if (name == null || name == "")
			fail('<pkgconfig> needs a "name" attribute.');
		if (pkgCache.exists(name))
			return pkgCache.get(name);

		function query(flag:String):Array<String> {
			var out:String = "";
			var err:String = "";
			var code:Int = -1;
			try {
				var p:Process = new Process("pkg-config", [flag, name]);
				out = p.stdout.readAll().toString();
				err = p.stderr.readAll().toString();
				code = p.exitCode();
				p.close();
			} catch (e:Dynamic) {
				fail('pkg-config is not available ($e).\n  Install it (Linux: pkg-config, macOS: brew install pkg-config), or describe the library with <lib>/<files> and an if="..." condition.');
			}
			if (code != 0)
				fail('pkg-config $flag $name failed: ${err.trim()}\n  Is the development package for "$name" installed?');
			return [for (t in out.trim().split(" ")) if (t.trim() != "") t.trim()];
		}

		var libs:Array<String> = [];
		var raw:Array<String> = query("--libs");
		var i:Int = 0;
		while (i < raw.length) {
			if (raw[i] == "-framework" && i + 1 < raw.length) {
				libs.push("-framework " + raw[i + 1]);
				i += 2;
			} else {
				libs.push(raw[i]);
				i++;
			}
		}

		var res:{cflags:Array<String>, libs:Array<String>} = {cflags: query("--cflags"), libs: libs};
		pkgCache.set(name, res);
		return res;
	}

	static function moduleGlobalsText(m:HlModule):String {
		var buf:StringBuf = new StringBuf();
		for (e in m.root.elements()) {
			var rawGroup:Bool = e.nodeName == "files" && e.get("id") != null;
			if (rawGroup || moduleGlobalTags.indexOf(e.nodeName) >= 0)
				buf.add('    ' + e.toString() + '\n');
			else if (moduleLocalTags.indexOf(e.nodeName) < 0)
				info('Warning: ${m.name}: unknown element <${e.nodeName}> in ${MODULE_FILE} was ignored.');
		}
		return buf.toString();
	}

	static function addModuleGlobals(buf:StringBuf):Void {
		var modules:Array<HlModule> = getModules();
		for (m in modules)
			buf.add('    <set name="HLMODULE_${moduleVar(m)}_DIR" value="${m.dir}" />\n');
		for (m in modules)
			buf.add(moduleGlobalsText(m));
		buf.add('\n');
	}

	static function moduleFilesText(m:HlModule, group:String):String {
		var buf:StringBuf = new StringBuf();
		for (b in m.root.elements()) {
			if (b.nodeName != "files" || b.get("id") != null || !conditionMet(b))
				continue;
			var g:String = b.get("group");
			if (g == null)
				g = "natives";
			if (g != "natives" && g != "hlc")
				fail('${m.file}: <files group="$g"> is not valid (use "natives" or "hlc").');
			if (g != group)
				continue;
			for (c in b.elements())
				buf.add('        ' + c.toString() + '\n');
		}
		if (group == "natives") {
			for (b in m.root.elements())
				if (b.nodeName == "pkgconfig" && conditionMet(b))
					for (f in pkgConfig(b.get("name")).cflags)
						buf.add('        <compilerflag value="${StringTools.htmlEscape(f, true)}" />\n');
		}
		return buf.toString();
	}

	static function addModuleFiles(buf:StringBuf, group:String):Void {
		for (m in getModules())
			buf.add(moduleFilesText(m, group));
	}

	static function moduleTargetText(m:HlModule):String {
		var buf:StringBuf = new StringBuf();
		for (b in m.root.elements()) {
			if (b.nodeName != "target" || !conditionMet(b))
				continue;
			for (c in b.elements())
				buf.add('        ' + c.toString() + '\n');
		}
		for (b in m.root.elements())
			if (b.nodeName == "pkgconfig" && conditionMet(b))
				for (l in pkgConfig(b.get("name")).libs)
					buf.add('        <lib name="${StringTools.htmlEscape(l, true)}" />\n');
		return buf.toString();
	}

	static function addModuleTarget(buf:StringBuf):Void {
		for (m in getModules())
			buf.add(moduleTargetText(m));
	}

	static function moduleHdllRoots():Array<{root:String, owner:String}> {
		var out:Array<{root:String, owner:String}> = [];
		for (m in getModules()) {
			for (b in m.root.elements()) {
				if (b.nodeName != "hdlls" || !conditionMet(b))
					continue;
				var d:String = b.get("dir");
				if (d == null || d == "")
					fail('${m.file}: <hdlls> needs a "dir" attribute.');
				out.push({root: resolveModulePath(m, d), owner: m.name});
			}
		}
		return out;
	}

	static function ensureDir(dir:String):Void {
		if (dir == "" || FileSystem.exists(dir))
			return;
		var parent:String = Path.directory(dir);
		if (parent != "" && parent != dir)
			ensureDir(parent);
		FileSystem.createDirectory(dir);
	}

	static function copyRecursive(src:String, dst:String):Bool {
		var changed:Bool = false;
		if (FileSystem.isDirectory(src)) {
			ensureDir(dst);
			for (item in FileSystem.readDirectory(src))
				if (copyRecursive(Path.join([src, item]), Path.join([dst, item])))
					changed = true;
		} else {
			ensureDir(Path.directory(dst));
			changed = copyIfChanged(src, dst);
		}
		return changed;
	}

	static function copyModuleFiles(outputDir:String):Void {
		var targetDir:String = Path.join([outputDir, "build", folder]);
		for (m in getModules()) {
			for (b in m.root.elements()) {
				if (b.nodeName != "copy" || !conditionMet(b))
					continue;
				var from:String = b.get("from");
				if (from == null || from == "")
					fail('${m.file}: <copy> needs a "from" attribute.');
				var src:String = resolveModulePath(m, from);
				if (!FileSystem.exists(src)) {
					if (b.get("optional") == "true")
						continue;
					fail('${m.name}: <copy from="$from"> not found: $src');
				}
				var to:String = b.get("to");
				var dstDir:String = (to == null || to == "") ? targetDir : Path.join([targetDir, to]);
				var changed:Bool = FileSystem.isDirectory(src) ? copyRecursive(src,
					dstDir) : copyRecursive(src, Path.join([dstDir, Path.withoutDirectory(src)]));
				if (changed)
					info('Copied (${m.name}): ${Path.withoutDirectory(src)} -> $dstDir');
			}
		}
	}

	static function collectModuleStamp(m:HlModule, out:Array<String>):Void {
		out.push(statLine(m.file));
		stampXmlFiles(m.root, out);
		for (d in moduleIncludeDirs(m))
			collectStampNatives(d, "", out);
		for (b in m.root.elements()) {
			if (b.nodeName == "copy" && b.get("from") != null) {
				var src:String = resolveModulePath(m, b.get("from"));
				if (FileSystem.exists(src) && !FileSystem.isDirectory(src))
					out.push(statLine(src));
			}
		}
	}

	static function moduleIncludeDirs(m:HlModule):Array<String> {
		var seen:Map<String, Bool> = new Map();
		var out:Array<String> = [];
		collectIncludeDirs(m.root, seen, out);
		return out;
	}

	static function collectIncludeDirs(x:Xml, seen:Map<String, Bool>, out:Array<String>):Void {
		for (e in x.elements()) {
			var v:String = e.get("value");
			if (e.nodeName == "compilerflag" && v != null && v.startsWith("-I")) {
				var d:String = Path.removeTrailingSlashes(Path.normalize(v.substr(2).trim()));
				if (!seen.exists(d) && d != hlIncludeDir && FileSystem.exists(d) && FileSystem.isDirectory(d)) {
					seen.set(d, true);
					out.push(d);
				}
			}
			collectIncludeDirs(e, seen, out);
		}
	}

	static function stampXmlFiles(x:Xml, out:Array<String>):Void {
		for (e in x.elements()) {
			if ((e.nodeName == "file" || e.nodeName == "depend" || e.nodeName == "lib") && e.get("name") != null) {
				var n:String = e.get("name");
				if (FileSystem.exists(n) && !FileSystem.isDirectory(n))
					out.push(statLine(n));
			}
			stampXmlFiles(e, out);
		}
	}

	static inline var INJECTIONS_HDLL:String = "hashlinkinjections";

	static function isVmOutput():Bool {
		var output:String = Compiler.getOutput();
		return output != null && Path.extension(output).toLowerCase() == "hl";
	}

	static function vmFileName():String {
		return os == "Windows" ? "hl.exe" : "hl";
	}

	static function ensureVm():String {
		var vm:String = Path.join([hlLibDir, vmFileName()]);
		if (FileSystem.exists(vm))
			return vm;

		info('HashLink VM not found. Building it first...');
		var old:String = Sys.getCwd();
		Sys.setCwd(haxelibPath);
		compileBuildXml(haxelibPath, "BuildHashlink.xml", null, null, "vm");
		Sys.setCwd(old);

		if (!FileSystem.exists(vm))
			fail('The HashLink VM was not produced: $vm');
		return vm;
	}

	static function splitFlags(v:String):Array<String> {
		if (v == null || v == "" || v == "1")
			return [];
		return [for (f in v.split(" ")) if (f.trim() != "") f.trim()];
	}

	static function userCFlags():Array<String> {
		var f:Array<String> = splitFlags(Context.definedValue("hl_cflags"));
		if (Context.defined("hl_lto"))
			f.push(os == "Windows" ? "/GL" : "-flto");
		if (Context.defined("hl_asan") && os != "Windows" && os != "WebAssembly") {
			f.push("-fsanitize=address");
			f.push("-fno-omit-frame-pointer");
		}
		return f;
	}

	static function userLinkFlags():Array<String> {
		var f:Array<String> = splitFlags(Context.definedValue("hl_ldflags"));
		if (Context.defined("hl_lto"))
			f.push(os == "Windows" ? "/LTCG" : "-flto");
		if (Context.defined("hl_asan") && os != "Windows" && os != "WebAssembly")
			f.push("-fsanitize=address");
		return f;
	}

	static function addUserCFlags(buf:StringBuf):Void {
		for (f in userCFlags())
			buf.add('        <compilerflag value="${StringTools.htmlEscape(f, true)}" />\n');
	}

	static function addUserLinkFlags(buf:StringBuf):Void {
		for (f in userLinkFlags())
			buf.add('        <flag value="${StringTools.htmlEscape(f, true)}" />\n');
	}

	static function addHeaderDepends(buf:StringBuf, dirs:Array<String>):Void {
		var seen:Map<String, Bool> = new Map();
		function walk(dir:String):Void {
			if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
				return;
			var items:Array<String> = FileSystem.readDirectory(dir);
			items.sort(Reflect.compare);
			for (item in items) {
				if (item.startsWith("."))
					continue;
				var full:String = Path.join([dir, item]);
				if (FileSystem.isDirectory(full)) {
					walk(full);
				} else {
					var ext:String = Path.extension(item).toLowerCase();
					if ((ext == "h" || ext == "hpp") && !seen.exists(full)) {
						seen.set(full, true);
						buf.add('        <depend name="$full" />\n');
					}
				}
			}
		}
		for (d in dirs)
			walk(d);
	}

	static function copyIfChanged(src:String, dst:String):Bool {
		if (FileSystem.exists(dst) && FileSystem.stat(dst).size == FileSystem.stat(src).size) {
			var a:haxe.io.Bytes = File.getBytes(src);
			var b:haxe.io.Bytes = File.getBytes(dst);
			if (a.compare(b) == 0)
				return false;
		}
		try {
			File.copy(src, dst);
		} catch (e:Dynamic) {
			fail('Could not write $dst ($e).\n  A running program keeps its files busy: close it and build again.');
		}
		return true;
	}

	static function makeExecutable(path:String):Void {
		if (Sys.systemName() != "Windows")
			Sys.command("chmod", ["+x", path]);
	}

	static function hasNativeSources(dir:String):Bool {
		if (!FileSystem.exists(dir) || !FileSystem.isDirectory(dir))
			return false;
		for (f in FileSystem.readDirectory(dir)) {
			var full:String = Path.join([dir, f]);
			if (FileSystem.isDirectory(full)) {
				if (hasNativeSources(full))
					return true;
			} else {
				var ext:String = Path.extension(f).toLowerCase();
				if (ext == "c" || ext == "cpp" || ext == "c++")
					return true;
			}
		}
		return false;
	}

	static function collectHdllUnits(projectPath:String, absOut:String):Array<HdllUnit> {
		var units:Array<HdllUnit> = [];
		var owners:Map<String, String> = new Map();

		function add(u:HdllUnit, owner:String):Void {
			if (owners.exists(u.name))
				fail('Both ${owners.get(u.name)} and $owner produce "${u.name}.hdll". Rename one of them.');
			owners.set(u.name, owner);
			units.push(u);
		}

		var natives:String = Path.join([projectPath, "natives"]);
		var hasNativesDir:Bool = FileSystem.exists(natives) && FileSystem.isDirectory(natives);

		var shared:{
			files:String,
			target:String,
			globals:String,
			stamp:Array<String>,
			dirs:Array<String>
		} = {
			files: "",
			target: "",
			globals: "",
			stamp: [],
			dirs: []
		};
		for (m in getModules()) {
			var files:String = moduleFilesText(m, "natives");
			if (files.indexOf("<file ") >= 0)
				continue;
			shared.files += files;
			shared.target += moduleTargetText(m);
			shared.globals += moduleGlobalsText(m);
			collectModuleStamp(m, shared.stamp);
			shared.dirs = shared.dirs.concat(moduleIncludeDirs(m));
		}

		function dirUnit(name:String, dir:String):HdllUnit {
			var incDirs:Array<String> = [dir];
			if (hasNativesDir && natives != dir)
				incDirs.push(natives);

			var b:StringBuf = new StringBuf();
			for (d in incDirs)
				b.add('        <compilerflag value="-I$d" />\n');
			addFilesRecursively(dir, b);
			b.add(shared.files);

			var t:StringBuf = new StringBuf();
			var stamp:Array<String> = shared.stamp.copy();
			if (hasNativesDir) {
				for (l in collectNativeStaticLibs(natives)) {
					t.add('        <lib name="$l" />\n');
					stamp.push(statLine(l));
				}
			}
			t.add(shared.target);

			for (d in incDirs)
				collectStampNatives(d, "", stamp);
			return {
				name: name,
				filesXml: b.toString(),
				targetXml: t.toString(),
				globalsXml: shared.globals,
				stamp: stamp,
				includeDirs: incDirs.concat(shared.dirs)
			};
		}

		var injections:String = Path.join([absOut, "injections"]);
		var hasInjections:Bool = hasNativeSources(injections);
		if (hasInjections)
			add(dirUnit(INJECTIONS_HDLL, injections), "@:injectNativeFunction");

		var hasNativeLibs:Bool = hasNativesDir && collectNativeStaticLibs(natives).length > 0;
		if (hasNativeSources(natives)) {
			var n:String = Context.definedValue("hl_natives_hdll");
			if (n == null || n == "" || n == "1")
				n = "natives";
			add(dirUnit(n, natives), "natives/");
			if (hasInjections && hasNativeLibs)
				info('The static libraries of natives/ are linked into both $INJECTIONS_HDLL.hdll and $n.hdll: each hdll has its own copy of their state. '
					+ 'Keep the code that uses one of them in a single place.');
		}

		for (m in getModules()) {
			var files:String = moduleFilesText(m, "natives");
			if (files.indexOf("<file ") < 0)
				continue;
			var stamp:Array<String> = [];
			collectModuleStamp(m, stamp);
			add({
				name: m.name,
				filesXml: files,
				targetXml: moduleTargetText(m),
				globalsXml: moduleGlobalsText(m),
				stamp: stamp,
				includeDirs: moduleIncludeDirs(m)
			}, 'module ${m.name}');
		}

		return units;
	}

	static function hdllXml(u:HdllUnit, useCache:Bool):String {
		var b:StringBuf = new StringBuf();
		b.add('<xml>\n');
		b.add('    <set name="HL_FOLDER" value="$folder" />\n');
		b.add('    <set name="HL_INCLUDE" value="$hlIncludeDir" />\n');
		for (m in getModules())
			b.add('    <set name="HLMODULE_${moduleVar(m)}_DIR" value="${m.dir}" />\n');
		b.add(u.globalsXml);

		b.add('    <files id="sources">\n');
		b.add('        <compilerflag value="-I$hlIncludeDir" />\n');
		b.add('        <compilerflag value="-DHL_COMPILE_VM" />\n');
		addUserCFlags(b);
		if (useCache) {
			b.add('        <cache value="true" project="hdll_${u.name}" />\n');
			addHeaderDepends(b, u.includeDirs);
		}
		b.add(u.filesXml);
		b.add('    </files>\n\n');

		b.add('    <target id="default" tool="linker" toolid="dll" output="${u.name}" rebuild="true">\n');
		b.add('        <ext value=".hdll" />\n');
		b.add('        <outdir name="out" />\n');
		addUserLinkFlags(b);
		b.add('        <files id="sources" />\n');
		if (os == "Windows") {
			b.add('        <flag value="/NOIMPLIB" />\n');
			b.add('        <lib name="$hlLibFile" />\n');
		} else if (os == "Mac") {
			b.add('        <lib name="-Wl,-undefined,dynamic_lookup" />\n');
		} else {
			b.add('        <lib name="-Wl,-z,undefs" />\n');
		}
		b.add(u.targetXml);
		b.add('    </target>\n');
		b.add('</xml>\n');
		return b.toString();
	}

	static function buildHdllUnits(units:Array<HdllUnit>, absOut:String, cacheDir:String):Array<String> {
		var results:Array<String> = [];
		var stale:Array<{
			u:HdllUnit,
			dir:String,
			hdll:String,
			stamp:String,
			stampFile:String
		}> = [];
		var force:Bool = Context.defined("hl_force");

		for (u in units) {
			var dir:String = Path.join([absOut, "hdll", u.name]);
			ensureDir(dir);

			var xml:String = hdllXml(u, cacheDir != null);
			File.saveContent(Path.join([dir, "Build.xml"]), xml);

			var hdllFile:String = Path.join([dir, "out", u.name + ".hdll"]);
			var stampFile:String = Path.join([dir, ".stamp"]);
			var parts:Array<String> = [
				xml,
				os,
				arch,
				folder,
				statLine(hlLibFile),
				Context.defined("hl_fast") ? "fast" : "release"
			];
			var stamp:String = haxe.crypto.Md5.encode(parts.concat(u.stamp).join("\n"));

			results.push(hdllFile);
			if (!force && FileSystem.exists(hdllFile) && FileSystem.exists(stampFile) && File.getContent(stampFile) == stamp) {
				info('hdll "${u.name}" is up to date.');
				continue;
			}
			if (FileSystem.exists(stampFile))
				FileSystem.deleteFile(stampFile);
			var objDir:String = Path.join([dir, "obj"]);
			if (FileSystem.exists(objDir)) {
				try {
					deleteDirectoryRecursive(objDir);
				} catch (e:Dynamic) {}
			}
			stale.push({
				u: u,
				dir: dir,
				hdll: hdllFile,
				stamp: stamp,
				stampFile: stampFile
			});
		}

		if (stale.length == 0)
			return results;

		var jobs:Int = 4;
		var jv:String = Context.definedValue("hl_jobs");
		if (jv != null && Std.parseInt(jv) != null)
			jobs = Std.parseInt(jv);
		jobs = Std.int(Math.min(jobs, stale.length));

		if (jobs <= 1) {
			for (s in stale) {
				info('Building hdll "${s.u.name}"...');
				compileBuildXml(absOut, "Build.xml", s.dir, cacheDir);
			}
		} else {
			info('Building ${stale.length} hdlls (${stale.map(s -> s.u.name).join(", ")}) with $jobs parallel jobs...');
			var outputs:Array<{code:Int, output:String}> = runHxcppParallel(stale.map(s -> s.dir), cacheDir, jobs);
			var failed:Bool = false;
			for (i in 0...stale.length) {
				if (outputs[i].code != 0) {
					failed = true;
					Sys.println('--- hdll "${stale[i].u.name}" failed (exit code ${outputs[i].code}) ---');
					Sys.println(outputs[i].output);
				}
			}
			if (failed)
				fail('One or more hdlls failed to build.');
		}

		for (s in stale) {
			if (!FileSystem.exists(s.hdll))
				fail('hxcpp did not produce ${s.hdll}');
			File.saveContent(s.stampFile, s.stamp);
		}
		return results;
	}

	static function runHxcppParallel(dirs:Array<String>, cacheDir:String, limit:Int):Array<{code:Int, output:String}> {
		var results:Array<{code:Int, output:String}> = [for (d in dirs) null];

		var hxArgs:Array<String> = hxcppArgs("Build.xml", cacheDir, null);
		hxArgs.push("-DHXCPP_CACHE_MB=0");
		var hx:String = ["haxelib", "run", "hxcpp"].concat(hxArgs.map(quoteIfNeeded)).join(" ");
		var windows:Bool = Sys.systemName() == "Windows";

		var next:Int = 0;
		while (next < dirs.length) {
			var wave:Array<{index:Int, proc:Process, log:String}> = [];
			while (wave.length < limit && next < dirs.length) {
				var i:Int = next++;
				var log:String = Path.join([dirs[i], "build.log"]);
				try {
					var proc:Process;
					if (windows) {
						var bat:String = Path.join([dirs[i], "build.bat"]);
						File.saveContent(bat, '@echo off\r\n' + 'cd /d "%~dp0"\r\n' + hx + ' > "build.log" 2>&1\r\n' + 'exit /b %ERRORLEVEL%\r\n');
						proc = new Process("cmd", ["/c", bat]);
					} else {
						var cmd:String = 'cd "${dirs[i]}" && $hx > "$log" 2>&1';
						proc = new Process("sh", ["-c", cmd]);
					}
					wave.push({index: i, proc: proc, log: log});
				} catch (e:Dynamic) {
					results[i] = {code: -1, output: 'Could not start hxcpp: $e'};
				}
			}
			for (w in wave) {
				var code:Int = w.proc.exitCode();
				w.proc.close();
				results[w.index] = {
					code: code,
					output: FileSystem.exists(w.log) ? File.getContent(w.log) : ""
				};
			}
		}
		return results;
	}

	static function hdllExportedPrims(path:String):Array<String> {
		var out:Array<String> = [];
		if (os == "Windows") {
			for (e in readExports(path))
				if (e.startsWith("hlp_"))
					out.push(e.substr(4));
			return out;
		}
		try {
			var proc:Process = new Process("nm", os == "Mac" ? ["-gU", path] : ["-D", "--defined-only", path]);
			var text:String = proc.stdout.readAll().toString();
			proc.exitCode();
			proc.close();
			var re:EReg = ~/[ ]_?hlp_([A-Za-z0-9_]+)/;
			for (line in text.split("\n"))
				if (re.match(line))
					out.push(re.matched(1));
		} catch (e:Dynamic) {
			return null;
		}
		return out;
	}

	static function checkVmNatives(bytecode:String, buildDir:String):Void {
		var natives:Array<HlNative>;
		try {
			natives = HlBytecode.readNatives(File.getBytes(bytecode));
		} catch (e:Dynamic) {
			info('Could not read the native table of $bytecode ($e): the check for missing hdlls was skipped.');
			return;
		}

		var byLib:Map<String, Array<HlNative>> = new Map();
		var libs:Array<String> = [];
		for (n in natives) {
			if (n.lib == "std" || n.lib == "builtin")
				continue;
			if (!byLib.exists(n.lib)) {
				byLib.set(n.lib, []);
				libs.push(n.lib);
			}
			byLib.get(n.lib).push(n);
		}

		var problems:Int = 0;
		for (lib in libs) {
			var fns:Array<HlNative> = byLib.get(lib);
			var required:Array<HlNative> = fns.filter(f -> !f.optional);
			var file:String = Path.join([buildDir, lib + "64.hdll"]);
			if (!FileSystem.exists(file))
				file = Path.join([buildDir, lib + ".hdll"]);

			if (!FileSystem.exists(file)) {
				if (required.length == 0)
					continue;
				problems++;
				var sample:String = required.slice(0, 3).map(f -> f.name).join(", ") + (required.length > 3 ? ", ..." : "");
				info('Warning: the program needs "$lib.hdll" (${required.length} function(s): $sample) but it was not built or found.\n'
					+ '  Put a prebuilt one in hdlls/dynamic/$folder, or provide it with an hl_module.xml whose name is "$lib".');
				continue;
			}

			var prims:Array<String> = hdllExportedPrims(file);
			if (prims == null)
				continue;
			var missing:Array<String> = [for (f in required) if (prims.indexOf(f.name) < 0) f.name];
			if (missing.length > 0) {
				problems++;
				info('Warning: ${Path.withoutDirectory(file)} does not export ${missing.length} function(s) the program needs: ${missing.slice(0, 5).join(", ")}'
					+ (missing.length > 5 ? ", ..." : "")
					+ '.\n  Each one needs HL_PRIM + DEFINE_PRIM in the hdll source (see "Modules" in the README).');
			}
		}

		if (problems > 0 && Context.defined("hl_strict_natives"))
			fail('$problems native library problem(s) found (-D hl_strict_natives is set).');
	}

	static function buildVm(projectPath:String, outputDir:String):Void {
		var absOut:String = Path.isAbsolute(outputDir) ? outputDir : Path.join([projectPath, outputDir]);
		var buildDir:String = Path.join([absOut, "build", folder]);
		ensureDir(buildDir);

		info('VM mode: bytecode on the precompiled HashLink VM, native code in hdlls.');
		var vm:String = ensureVm();

		var nativeLibs:NativeLibs = resolveNativeLibs(projectPath);
		if (nativeLibs.statics.length > 0)
			info('Static libs are ignored in VM mode (hdlls are loaded at run time): ' + nativeLibs.statics.map(l -> l.fileName).join(", "));

		var built:Array<String> = buildHdllUnits(collectHdllUnits(projectPath, absOut), absOut, resolveCacheDir(absOut));

		var exePath:String = Path.join([buildDir, exeFileName()]);
		if (copyIfChanged(vm, exePath))
			makeExecutable(exePath);

		var bytecode:String = Compiler.getOutput();
		if (!Path.isAbsolute(bytecode))
			bytecode = Path.join([projectPath, bytecode]);
		copyIfChanged(bytecode, Path.join([buildDir, "hlboot.dat"]));

		copyHdlls(projectPath, outputDir);
		for (h in built)
			copyIfChanged(h, Path.join([buildDir, Path.withoutDirectory(h)]));
		copyModuleFiles(outputDir);
		checkVmNatives(bytecode, buildDir);

		info('VM ready: ${Path.join([outputDir, "build", folder, exeFileName()])} (runs hlboot.dat)');
	}

	static function getHaxelibPath():String {
		var proc:Process = new Process("haxelib", ["path", "hl_compile"]);
		var lines:Array<String> = proc.stdout.readAll().toString().split("\n");
		proc.close();
		return Path.normalize(StringTools.trim(lines[2]));
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
