#!/usr/bin/env bash
# Builds tests/smoke in HashLink/C mode and (on x86-64) in bytecode/VM mode, and checks what each one prints.
# Needs: haxe, hxcpp, and hl_compile registered with `haxelib dev hl_compile <this repository>`.
set -euo pipefail

# Pause when the script ends, whatever the exit code is (success or failure),
# so the window does not close before the result can be read.
pause() {
	local code=$?
	echo
	read -r -p "Press Enter to close..." _ || true
	exit "$code"
}
trap pause EXIT

cd "$(dirname "$0")/smoke/app"

exe() {
	if [ -f "$1/output.exe" ]; then echo "$1/output.exe"; else echo "$1/output"; fi
}

check() {
	local got want
	got="$("$1" | tr -d '\r')"
	want="$(tr -d '\r' < ../expected.txt)"
	if [ "$got" != "$want" ]; then
		echo "Unexpected output from $1:"
		echo "$got"
		exit 1
	fi
	echo "ok: $1"
}

rm -rf bin

echo "== HashLink/C (--release)"
haxelib run hl_compile build build.hxml --release
check "$(exe bin/release/build/*)"
[ -f bin/release/build/*/assets/hello.txt ] || { echo "the module's assets were not copied"; exit 1; }

case "$(uname -m)" in
	x86_64 | AMD64 | x64)
		echo "== bytecode on the VM"
		haxelib run hl_compile build build.hxml
		check "$(exe bin/build/*)"
		for h in hashlinkinjections natives hlfw; do
			[ -f bin/build/*/$h.hdll ] || { echo "$h.hdll was not built"; exit 1; }
		done
		echo "== second build must not rebuild any hdll"
		again="$(haxelib run hl_compile build build.hxml)"
		case "$again" in
			*"is up to date"*) ;;
			*) echo "hdlls were rebuilt"; exit 1 ;;
		esac
		;;
	*)
		echo "== bytecode mode skipped: the HashLink JIT needs an x86-64 machine"
		;;
esac
echo "smoke test passed"