package hlcompiler;

import haxe.io.Bytes;

typedef HlNative = {
	var lib:String;
	var name:String;
	var optional:Bool;
}

class HlBytecode {
	var b:Bytes;
	var pos:Int = 0;
	var version:Int = 0;
	var strings:Array<String> = [];

	function new(b:Bytes) {
		this.b = b;
	}

	function u8():Int {
		if (pos >= b.length)
			throw "Unexpected end of bytecode";
		return b.get(pos++);
	}

	function i32():Int {
		if (pos + 4 > b.length)
			throw "Unexpected end of bytecode";
		var v = b.getInt32(pos);
		pos += 4;
		return v;
	}

	function index():Int {
		var c = u8();
		if ((c & 0x80) == 0)
			return c & 0x7F;
		if ((c & 0x40) == 0) {
			var v = u8() | ((c & 31) << 8);
			return (c & 0x20) == 0 ? v : -v;
		}
		var d = u8();
		var e = u8();
		var f = u8();
		var v = ((c & 31) << 24) | (d << 16) | (e << 8) | f;
		return (c & 0x20) == 0 ? v : -v;
	}

	function uindex():Int {
		var i = index();
		if (i < 0)
			throw "Negative index in bytecode";
		return i;
	}

	function readStrings(n:Int):Array<String> {
		var size = i32();
		if (size < 0 || pos + size > b.length)
			throw "Invalid string table";
		var base = pos;
		pos += size;
		var out:Array<String> = [];
		var p = base;
		for (i in 0...n) {
			var len = uindex();
			if (p + len >= base + size)
				throw "Invalid string";
			out.push(b.getString(p, len));
			p += len + 1;
		}
		return out;
	}

	function readType():Void {
		var kind = u8();
		switch (kind) {
			case 10 | 20:
				var nargs = u8();
				for (i in 0...nargs)
					index();
				index();
			case 11 | 21:
				index();
				index();
				uindex();
				var nfields = uindex();
				var nproto = uindex();
				var nbindings = uindex();
				for (i in 0...nfields) {
					index();
					index();
				}
				for (i in 0...nproto) {
					index();
					uindex();
					index();
				}
				for (i in 0...nbindings) {
					uindex();
					uindex();
				}
			case 15:
				var nfields = uindex();
				for (i in 0...nfields) {
					index();
					index();
				}
			case 17:
				index();
			case 18:
				index();
				uindex();
				var nconstructs = uindex();
				for (i in 0...nconstructs) {
					index();
					var nparams = uindex();
					for (j in 0...nparams)
						index();
				}
			case 14 | 19 | 22:
				index();
			default:
				if (kind >= 24)
					throw "Invalid type in bytecode";
		}
	}

	function str(i:Int):String {
		if (i < 0 || i >= strings.length)
			throw "Invalid string index in bytecode";
		return strings[i];
	}

	function natives():Array<HlNative> {
		if (u8() != 'H'.code || u8() != 'L'.code || u8() != 'B'.code)
			throw "Not a HashLink bytecode file";
		version = u8();
		if (version <= 1 || version > 6)
			throw "Unsupported bytecode version " + version;

		var flags = uindex();
		var nints = uindex();
		var nfloats = uindex();
		var nstrings = uindex();
		var nbytes = version >= 5 ? uindex() : 0;
		var ntypes = uindex();
		var nglobals = uindex();
		var nnatives = uindex();
		uindex();
		if (version >= 4)
			uindex();
		uindex();

		pos += nints * 4;
		pos += nfloats * 8;
		strings = readStrings(nstrings);
		if (version >= 5) {
			var size = i32();
			pos += size;
			for (i in 0...nbytes)
				uindex();
		}
		if ((flags & 1) != 0) {
			var ndebug = uindex();
			readStrings(ndebug);
		}
		for (i in 0...ntypes)
			readType();
		for (i in 0...nglobals)
			index();

		var out:Array<HlNative> = [];
		for (i in 0...nnatives) {
			var lib = str(index());
			var name = str(index());
			index();
			uindex();
			var optional = lib.charAt(0) == "?";
			out.push({lib: optional ? lib.substr(1) : lib, name: name, optional: optional});
		}
		return out;
	}

	public static function readNatives(bytes:Bytes):Array<HlNative> {
		return new HlBytecode(bytes).natives();
	}
}
