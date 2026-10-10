class Main {
	static function inc(x:Int):Int return x + 1;

	static function main() {
		Sys.println("answer=" + Fw.answer());
		Sys.println("inj=" + Inj.twice("abc", 1));
		Sys.println("mul=" + Inj.mul(1.5, 4));
		Sys.println("nat=" + Nat.triple(14));
		Sys.println("null=" + Inj.nothing(true));
		Sys.println("apply=" + Inj.apply(inc, 41));
	}
}
