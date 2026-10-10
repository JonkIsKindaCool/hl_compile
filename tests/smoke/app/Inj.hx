@:injectHeaderCode("static int inj_calls = 0;")
class Inj {
	@:injectNativeFunction("inj_calls++; return name->length * 2 + x + inj_calls;")
	public static function twice(name:String, x:Int):Int { return 0; }

	@:injectNativeFunction("return a * b;")
	public static function mul(a:Float, b:Float):Float { return 0.; }

	@:injectNativeFunction("return flag ? NULL : hl_alloc_dynamic(&hlt_i32);")
	public static function nothing(flag:Bool):Null<Int> { return null; }

	@:injectNativeFunction("return ((int(*)(int))f->fun)(v);")
	public static function apply(f:Int->Int, v:Int):Int { return 0; }
}
