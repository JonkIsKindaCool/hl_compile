package hlcompiler.macros;

import haxe.macro.Compiler;
import sys.io.File;
import sys.FileSystem;
import haxe.io.Path;
#if macro
import haxe.macro.Context;
import haxe.macro.Expr;

class NativeExecutionMacro {
	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		var clazz_ref = Context.getLocalClass();

		if (clazz_ref == null)
			return fields;

		var clazz = clazz_ref.get();

		var output = Compiler.getOutput();
		var vm = output != null && Path.extension(output).toLowerCase() == "hl";

		var prefixBuf = new StringBuf();
		for (meta in clazz.meta.get()) {
			if (meta.name == ":injectHeaderCode") {
				switch (meta.params[0].expr) {
					case EConst(CString(s, _)):
						prefixBuf.add(s);
						prefixBuf.add('\n');
					case _:
						Context.error("Expected String on @:injectHeaderCode", meta.params[0].pos);
				}
			}
		}

		var functionsBuf = new StringBuf();

		for (field in fields) {
			switch (field.kind) {
				case FFun(func):
					var injectCode:Null<String> = null;

					for (meta in field.meta) {
						if (meta.name == ":injectNativeFunction") {
							switch (meta.params[0].expr) {
								case EConst(CString(s, _)):
									injectCode = s;
								case _:
									Context.error("Expected String on @:injectNativeFunction", meta.params[0].pos);
							}
						}
					}

					if (injectCode != null) {
						var symbolSuffix = if (clazz.pack.length >= 1) {
							'${clazz.pack.join("_")}_${clazz.name}_${field.name}';
						} else {
							'${clazz.name}_${field.name}';
						};
						var fullSymbol = 'hashlinkinjections_$symbolSuffix';

						field.meta.push({
							name: ":hlNative",
							params: [macro "hashlinkinjections", macro $v{symbolSuffix}],
							pos: Context.currentPos()
						});

						var cArgs:Array<String> = [];
						var sigArgs:Array<String> = [];
						if (func.args != null) {
							for (arg in func.args) {
								var t = argType(arg);
								cArgs.push(hlTypeOf(t) + ' ' + arg.name);
								if (vm) {
									if (arg.type == null)
										Context.error('${field.name}: argument "${arg.name}" needs an explicit type to be injected in VM mode.', field.pos);
									sigArgs.push(hlSigOf(t, field.pos));
								}
							}
						}

						var fb = new StringBuf();
						if (vm) {
							fb.add('HL_PRIM ');
							fb.add(hlTypeOf(func.ret));
							fb.add(' HL_NAME($symbolSuffix)(');
							fb.add(cArgs.join(', '));
							fb.add(') {\n');
							fb.add(injectCode);
							fb.add('\n}\n');
							fb.add('DEFINE_PRIM(${hlSigOf(func.ret, field.pos)}, $symbolSuffix, ${sigArgs.length > 0 ? sigArgs.join(" ") : "_NO_ARG"})\n\n');
						} else {
							fb.add(hlTypeOf(func.ret));
							fb.add(' ');
							fb.add(fullSymbol);
							fb.add('(');
							fb.add(cArgs.join(', '));
							fb.add(') {\n');
							fb.add(injectCode);
							fb.add('\n}\n\n');
						}

						functionsBuf.add(fb.toString());
					}
				default:
			}
		}

		if (prefixBuf.length > 0 || functionsBuf.length > 0) {
			var classFolderName = if (clazz.pack.length >= 1) {
				clazz.pack.join("_") + "_" + clazz.name;
			} else {
				clazz.name;
			};

			if (output == null)
				Context.error("No output detected. Compile with -hl <file>.", Context.currentPos());

			var outputDir = Path.directory(Path.normalize(output));
			if (!Path.isAbsolute(outputDir)) {
				outputDir = Path.join([Sys.getCwd(), outputDir]);
			}

			var outDir = Path.join([outputDir, "injections", classFolderName]);
			if (!FileSystem.exists(outDir))
				FileSystem.createDirectory(outDir);

			var outFile = Path.join([outDir, classFolderName + ".c"]);

			var finalBuf = new StringBuf();
			if (vm)
				finalBuf.add('#define HL_NAME(n) hashlinkinjections_##n\n');
			finalBuf.add('#include <hl.h>\n\n');
			finalBuf.add(prefixBuf.toString());
			finalBuf.add(functionsBuf.toString());

			var code = finalBuf.toString();
			if (!FileSystem.exists(outFile) || File.getContent(outFile) != code)
				File.saveContent(outFile, code);
		}

		return fields;
	}

	static function argType(arg:FunctionArg):Null<ComplexType> {
		if (arg.opt == true && arg.type != null)
			return TPath({pack: [], name: "Null", params: [TPType(arg.type)]});
		return arg.type;
	}

	static function isBoxedWhenNull(name:String):Bool {
		return name == "Int" || name == "Float" || name == "Single" || name == "Bool";
	}

	static function nullInner(p:TypePath):Null<ComplexType> {
		if (p.params != null && p.params.length == 1) {
			switch (p.params[0]) {
				case TPType(inner):
					return inner;
				case TPExpr(_):
			}
		}
		return null;
	}

	static function hlTypeOf(ct:Null<ComplexType>):String {
		if (ct == null)
			return "void";

		return switch (ct) {
			case TPath(p):
				switch (p.name) {
					case "Int": "int";
					case "Float": "double";
					case "Single": "float";
					case "Bool": "bool";
					case "Void": "void";
					case "String": "vstring*";
					case "Bytes": "vbyte*";
					case "Dynamic": "vdynamic*";
					case "Any": "vdynamic*";
					case "NativeArray": "varray*";

					case "Array":
						"varray*";

					case "Null":
						var inner = nullInner(p);
						if (inner == null) {
							"vdynamic*";
						} else {
							switch (inner) {
								case TPath(ip) if (!isBoxedWhenNull(ip.name)): hlTypeOf(inner);
								case _: "vdynamic*";
							}
						}

					case "Virtual":
						"vdynamic*";

					default:
						"vdynamic*";
				}

			case TFunction(_, _):
				"vclosure*";

			case TAnonymous(_):
				"vdynamic*";

			case TParent(inner):
				hlTypeOf(inner);

			case TExtend(_, _):
				"vdynamic*";

			case TOptional(inner):
				hlTypeOf(inner);

			case TNamed(_, _):
				"vdynamic*";

			case TIntersection(_):
				"vdynamic*";
		}
	}

	static function hlSigOf(ct:Null<ComplexType>, pos:Position):String {
		if (ct == null)
			return "_VOID";

		return switch (ct) {
			case TPath(p):
				switch (p.name) {
					case "Int": "_I32";
					case "Float": "_F64";
					case "Single": "_F32";
					case "Bool": "_BOOL";
					case "Void": "_VOID";
					case "String": "_STRING";
					case "Bytes": "_BYTES";
					case "Dynamic" | "Any": "_DYN";
					case "NativeArray": "_ARR";
					case "Null":
						var inner = nullInner(p);
						if (inner == null) {
							"_DYN";
						} else {
							switch (inner) {
								case TPath(ip) if (isBoxedWhenNull(ip.name)): "_NULL(" + hlSigOf(inner, pos) + ")";
								case _: hlSigOf(inner, pos);
							}
						}
					default:
						Context.error('Type "${p.name}" cannot be used in an injected native function in VM mode: the hdll signature must match the bytecode type. '
							+ 'Use Int, Float, Single, Bool, String, hl.Bytes, hl.NativeArray, Dynamic, Null<T> or a function type.',
							pos);
						"";
				}

			case TFunction(args, ret):
				var a:Array<String> = [for (x in args) hlSigOf(x, pos)];
				"_FUN(" + hlSigOf(ret, pos) + ", " + (a.length > 0 ? a.join(" ") : "_NO_ARG") + ")";

			case TParent(inner):
				hlSigOf(inner, pos);

			case TOptional(inner):
				"_NULL(" + hlSigOf(inner, pos) + ")";

			default:
				Context.error("This type cannot be used in an injected native function in VM mode. Use Dynamic, or a basic type.", pos);
				"";
		}
	}
}
#end
