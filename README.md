# hl_compile

Compile **HashLink/C** (HLC) programs to a native executable — or to WebAssembly — straight from the Haxe
compiler. Add one library to your `.hxml`, run `haxe`, get an executable.

```hxml
--library hl_compile
--hl bin/main.c
--main Main
```

```
$ haxe build.hxml
[hlcompiler] Target platform: Windows (64)
[hlcompiler] Native libs (Windows64): static [glfw] dynamic [glad]
...
[hlcompiler] Build completed successfully.
```

`hl_compile` ships the HashLink runtime sources, builds them once for your platform, generates the build
file for the C code Haxe emitted, invokes the platform C compiler through [hxcpp](https://github.com/HaxeFoundation/hxcpp)
and links your native libraries (`.hdll` or static libraries). No CMake, no Visual Studio solution, no
Makefile to maintain.

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation and first build](#installation-and-first-build)
- [Quick start](#quick-start)
- [Command line tools](#command-line-tools)
- [Output layout](#output-layout)
- [Configuration (defines)](#configuration-defines)
- [Platforms and architectures](#platforms-and-architectures)
- [Native libraries (hdlls)](#native-libraries-hdlls)
- [Modules (frameworks)](#modules-frameworks)
- [Bytecode (VM) mode](#bytecode-vm-mode)
- [Injecting native code from Haxe](#injecting-native-code-from-haxe)
- [WebAssembly / Emscripten](#webassembly--emscripten)
- [How it works (backend)](#how-it-works-backend)
- [The one-runtime rule](#the-one-runtime-rule)
- [Writing native libraries for hl_compile](#writing-native-libraries-for-hl_compile)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Repository layout](#repository-layout)
- [License](#license)

## Features

- **One-step HLC build.** A Haxe macro (`hlcompiler.HlCompiler.init()`, registered automatically by
  `extraParams.hxml`) runs after Haxe generates the C code and builds the executable.
- **Self-contained.** The HashLink runtime sources (and PCRE2) are bundled; nothing to download or install
  besides a C toolchain and hxcpp.
- **Runtime built on demand and cached.** The first build compiles the runtime for your target into
  `libs/<Os><Arch>/`; later builds reuse it.
- **Windows, Linux and WebAssembly** as primary targets, with macOS, ARM, iOS and Android code paths
  (see [Platforms](#platforms-and-architectures) for their status).
- **Native libraries, both flavours.** Dynamic `.hdll` files loaded at runtime, and static libraries linked
  into the executable, side by side. If the same library exists in both, the static one wins.
- **Automatic Windows plumbing.** Import libraries for every `.hdll` are generated from its export table,
  hdlls are delay-loaded, the runtime DLL is copied next to the executable.
- **Guards against a classic HashLink crash.** It refuses to link a `.hdll` that carries its own copy of the
  runtime (see [the one-runtime rule](#the-one-runtime-rule)).
- **Architecture selection** (`x64`, `x86`, `arm64`, `arm7`) and **executable naming** through plain
  `-D` defines.

## Requirements

| | |
|---|---|
| Haxe | 4.3 or newer |
| hxcpp | `haxelib install hxcpp` (used to drive the C toolchain) |
| **Windows** | Visual Studio (2019 or newer recommended) or *Build Tools* with the **"Desktop development with C++"** workload (component `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`). It is located through `vswhere`; `dumpbin.exe` and `lib.exe` from that toolchain are used to generate import libraries. |
| **Linux** | `gcc` or `clang` with C11 support, plus the development packages your native libraries need (for GLFW: `libx11-dev`, `libgl1-mesa-dev`, ...). `nm` (binutils) is optional and enables an extra check. |
| **macOS** | Xcode command line tools. |
| **WebAssembly** | An activated [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html) (`emcc` reachable from the shell that runs `haxe`). |

## Installation and first build

```
haxelib install hl_compile
```

The first time you build for a given platform, `hl_compile` compiles the HashLink runtime and stores it in
the library folder:

```
<haxelib>/hl_compile/1,0,0/libs/<Os><Arch>/
```

Consequences worth knowing:

- The first build takes noticeably longer than the following ones.
- **The haxelib directory must be writable** for the user running `haxe`. If you use a system-wide haxelib
  repository owned by root, create a personal one (`haxelib newrepo`) or use `haxelib dev`.
- To force a rebuild of the runtime (for example after updating the library), delete the corresponding
  `libs/<Os><Arch>/` folder.

## Quick start

`build.hxml`:

```hxml
--library hl_compile
--hl bin/main.c
--main Main
```

`Main.hx`:

```haxe
class Main {
	static function main() {
		Sys.println("Hello from HashLink/C");
	}
}
```

```
haxe build.hxml
./bin/build/Linux64/output          # Windows: bin\build\Windows64\output.exe
```

The extension of the `--hl` output selects the mode. `--hl bin/main.c` makes Haxe emit HashLink/C and
`hl_compile` builds a native executable from it. `--hl bin/main.hl` makes Haxe emit bytecode and `hl_compile`
runs it on a precompiled VM, see [Bytecode (VM) mode](#bytecode-vm-mode). `hl_compile` uses the directory of
that file as its working directory.

## Command line tools

`haxelib run hl_compile <command>` wraps the common tasks. Everything also works by calling `haxe` yourself.

| Command | What it does |
|---|---|
| `doctor [--wasm]` | Checks Haxe, hxcpp, the C compiler (gcc/clang or Visual Studio), `nm`, the HashLink sources and the cached runtime and VM, and says how to fix what is missing. Exits with 1 if something blocks building. |
| `build <file.hxml> [--release]` | Development build: bytecode on the VM. With `--release`: HashLink/C into `<out>/release`, so both builds can live side by side. The `--hl` line of the `.hxml` only provides the location. Extra arguments go to `haxe`. |
| `run <file.hxml> [--release] [--debug [port]] [-- args]` | Builds and runs. `--debug` starts the VM waiting for a debugger on the port (default 6112). |
| `watch <file.hxml> [--run] [--hot]` | Rebuilds when a `.hx`, `.hxml`, C/C++ source or `hl_module.xml` changes. With `--run` the program is closed before each rebuild (its hdlls are loaded and cannot be overwritten) and started again after every successful build; if the build fails it stays stopped until one succeeds. A program that blocks for a long time, such as a window loop, does not hold up the watching. `--hot` (which implies `--run`) starts the VM with `--hot-reload` and keeps it running while only the bytecode changes; when native code changed and an hdll cannot be replaced, it closes the program and builds again. It is experimental: see below. |
| `clean [dir] [--runtime] [--global]` | Removes the build files (`obj`, caches, `hdll`, `build`, ...) of `dir` (default `bin`) and `dir/release`. `--runtime` also removes the cached runtime and VM. `--global` removes the folder in `HL_COMPILE_CACHE`. |
| `package [dir] [--name n] [--archive] [--app]` | Copies a build to `dist/<name>-<target>`, without build leftovers. `--archive` makes a `.tar.gz` (a `.zip` on Windows). `--app` creates a macOS `.app` bundle (`--id`, `--icon`). |
| `vscode [file.hxml]` | Creates `.vscode/tasks.json` and `launch.json` to build, start the VM waiting for a debugger and attach with the HashLink Debugger extension. Build with `-debug` for line information. |
| `new-module <name>` | Creates a framework skeleton: `haxelib.json`, `hl_module.xml`, a C file that works in both modes and its Haxe extern. |

**Hot reload.** The VM's `--hot-reload` swaps changed functions in a running program, which has to call
`hl.Api.checkReload()` regularly (Heaps does). In my tests (Haxe 4.3.6 and HashLink master) the VM crashed when it
applied a change, with the VM built by hl_compile and also with the one built by HashLink's own Makefile, so
`watch --run` restarts the program by default. Try `--hot` with a newer Haxe/HashLink.

**Debugging.** `run --debug` and the generated VS Code files rely on the VM's own debugger server. The files were
not tested against the HashLink Debugger extension.

## Output layout

```
bin/
├─ main.c                    HLC output generated by Haxe (plus hl/, _std/, haxe/, hlc.json, ...)
├─ Build-Windows64.xml       hxcpp build file generated by hl_compile (one per target)
└─ build/
   └─ Windows64/
      ├─ output.exe          your program            (WebAssembly: output.js + output.wasm)
      ├─ libhl.dll           runtime, Windows only
      └─ glfw.hdll ...       dynamic hdlls (and any .dll/.so/.dylib next to them)
```

- `bin/obj/` is temporary and is wiped on every build; the executable is rebuilt from scratch each time.
- Everything the program needs at runtime is inside `build/<Os><Arch>/`; that folder is what you ship.
- Static libraries are linked into the executable and are **not** copied.

## Configuration (defines)

All options are ordinary Haxe defines (`-D name` or `-D name=value`).

| Define | Effect |
|---|---|
| `hl_exe_name=<name>` | Name of the executable (default `output`). |
| `hl_compile_x64` / `hl_compile_x86` / `hl_compile_arm64` / `hl_compile_arm7` | Target architecture. Only one may be set. Default is 64-bit x86. `hl_compile_arm` is an alias of `hl_compile_arm64`. |
| `hl_force_windows` / `hl_force_linux` / `hl_force_mac` / `hl_force_ios` / `hl_force_android` | Override the detected host OS (advanced; you need a matching toolchain). |
| `hl_force_webassembly` | Build for WebAssembly. Also triggered by `hl_force_emscripten`, `emscripten`, `webassembly` and `wasm`. |
| `hl_cflags="..."` | Extra compiler flags for everything `hl_compile` compiles (generated C, `natives/`, modules, hdlls), separated by spaces. Cannot change the optimization level: hxcpp's toolchain fixes `-O2`. |
| `hl_ldflags="..."` | Extra linker flags for the executable and the hdlls. |
| `hl_lto` | Link-time optimization (`-flto`, or `/GL` + `/LTCG` with MSVC; the MSVC flags are untested). |
| `hl_asan` | AddressSanitizer on Linux and macOS (HashLink/C mode; the VM and its hdlls would need it too). |
| `hl_jobs=<n>` | VM mode: how many hdlls are built at the same time (default 4, `1` builds them one after another). |
| `hl_strict_natives` | VM mode: turn the warnings about missing hdlls/functions into an error. |
| `hl_natives_hdll=<name>` | VM mode only: name of the hdll built from the project's `natives/` folder (default `natives`). |
| `hl_allow_embedded_runtime` | Skip the check that rejects `.hdll` files containing their own HashLink runtime. Use only if you know exactly why. |

## Platforms and architectures

The target folder name is `<Os><Arch>`, where `Arch` is `64`, `32`, `Arm64` or `Arm7` (WebAssembly has none).
It is used for `libs/`, for `hdlls/` and for the output directory.

| Target | Folder | Status |
|---|---|---|
| Windows x64 | `Windows64` | Supported |
| Linux x64 | `Linux64` | Supported |
| WebAssembly (Emscripten) | `WebAssembly` | Supported |
| macOS x64 / arm64 | `Mac64` / `MacArm64` | Experimental |
| Linux arm64 / arm7 / x86 | `LinuxArm64` / `LinuxArm7` / `Linux32` | Experimental |
| Windows x86 | `Windows32` | Experimental |
| iOS, Android | `iPhone…`, `Android…` | Experimental, selected with `hl_force_*` |

*Experimental* means the code path exists but has not been validated end to end.

## Native libraries (hdlls)

Native libraries live next to your project, split by *how* they are linked:

```
hdlls/
├─ static/
│  └─ Windows64/    glfw_static.lib  glfw_static.deps      linked INTO the executable
└─ dynamic/
   └─ Windows64/    glad.hdll                              loaded at runtime
```

(`Windows64` is the target folder; use `Linux64`, `WebAssembly`, ... for the other targets.)

Rules:

1. **Both folders are linked.** A project can mix static and dynamic libraries.
2. **Static wins.** Libraries are matched by *id*. If the same id exists in both folders, only the static
   one is linked; the dynamic one is ignored and **not copied** to the build folder. A notice is printed.
3. **Ids.** The id is the file name without extension, with a `_static` suffix removed, and (on non-Windows)
   a leading `lib` removed. `glfw.hdll`, `glfw_static.lib`, `libglfw.a` and `glfw.a` are all the id `glfw`.
   Two static files that resolve to the same id are an error.
4. **Static file extension:** `.lib` on Windows, `.a` everywhere else. Dynamic libraries are `.hdll`.
5. **`.deps` files.** A static library does not remember what it needs from the system. Put a
   `<same name>.deps` file next to it: one linker argument per line, `#` starts a comment.

   ```
   # glfw_static.deps (Linux)
   -lGL
   -lX11
   -lpthread
   -ldl
   -lm
   ```

   Arguments the executable already links are not repeated. On Windows they are `.lib` names, on macOS
   `-framework X` lines are supported, and on WebAssembly any Emscripten link flag can be listed.
6. **Dynamic libraries on Windows** are delay-loaded, and an import library (`<name>.lib` + `<name>.def`)
   is generated next to each `.hdll` from its export table. Delete them to regenerate.
7. **Old layout.** If neither `hdlls/static` nor `hdlls/dynamic` exists but `hdlls/<Os><Arch>/` does, its
   contents are treated as dynamic and a notice asks you to move them.

The companion libraries `hl_glfw` and `hl_glad` produce both flavours:

```
haxelib run hl_glfw                  # glfw.hdll                       -> hdlls/dynamic/<Os><Arch>/
haxelib run hl_glfw --static-hdll    # glfw_static.lib|.a + .deps      -> hdlls/static/<Os><Arch>/
```

## Modules (frameworks)

A haxelib — or the project itself — can add native code to the final build by shipping an **`hl_module.xml`**.
It plays the role `include.xml` plays for hxcpp, but it is read by `hl_compile` and merged into the build
file it generates, so a framework can bring its own C/C++ sources, flags, libraries, hdlls and runtime files
without the user touching the `.hxml`.

```hxml
--library my_framework      # nothing else: its hl_module.xml is picked up automatically
--hl bin/main.c
--main Main
```

### Discovery

`hl_compile` looks for `hl_module.xml` in every Haxe class path, in the class path folder itself and in its
two parents (so both `<lib>/` and `<lib>/src/` layouts work; `haxelib dev` and `-cp` work too), and in the
project folder. Every module found is listed in the log: `[hlcompiler] Modules: my_framework, app`.

### Format

```xml
<hlmodule name="my_framework">                 <!-- name is optional (defaults to the folder name) -->

  <files>                                      <!-- compiled with your natives/ folder -->
    <compilerflag value="-I${HLMODULE_DIR}/native" />
    <file name="native/fw.c" />                <!-- relative to this file -->
    <file name="native/fw_win.c" if="windows" />
  </files>

  <files group="hlc">                          <!-- flags for the code Haxe generated -->
    <compilerflag value="-DMY_FRAMEWORK" />
  </files>

  <target>                                     <!-- libraries / linker flags of the executable -->
    <lib name="-lz" if="linux" />
    <lib name="native/${HL_FOLDER}/z.lib" if="windows" />
  </target>

  <hdlls dir="hdlls" />                        <!-- extra hdlls/ root (static/ and dynamic/) -->

  <copy from="assets" to="assets" />           <!-- copied into build/<target>/assets -->
  <copy from="bin/${HL_FOLDER}/extra.dll" optional="true" />

  <set name="MY_FRAMEWORK" value="1" />        <!-- plain hxcpp elements: pasted as they are -->
</hlmodule>
```

| Element | What it does |
|---|---|
| `<files>` | Its children (`<file>`, `<compilerflag>`, `<depend>`, ...) are added to the `natives` group. `group="hlc"` adds them to the group that compiles the Haxe-generated C instead. |
| `<files id="x">` | A complete hxcpp file group with its own id, pasted at the top level of the build file. Reference it from `<target>` with `<files id="x" />`. |
| `<target>` | Its children (`<lib>`, `<flag>`, `<section>`, ...) are added to the executable target. They are placed after the project's static libraries and before the system libraries. |
| `<hdlls dir="...">` | Another root laid out like the project's `hdlls/` (`static/<target>`, `dynamic/<target>`). See below for conflicts. |
| `<copy from="..." to="..." optional="true">` | Copies a file, or the contents of a folder, into `build/<target>/<to>` after the build. `to` is a folder. A missing source is an error unless `optional="true"`. |
| `<requires module="x" />`, `<requires define="x" />`, `<requires hl_compile="1.4.0" />` | Stops the build with a clear message when another module is not present, a `-D` is missing, or hl_compile is older than the given version. |
| `<pkgconfig name="sdl3" />` | Runs `pkg-config` and adds its compiler flags to the module's sources and its libraries to the link. Linux and macOS; on Windows describe the library with `<lib>` and an `if="windows"` condition. |
| `<set>`, `<unset>`, `<section>`, `<error>`, `<echo>` | Pasted verbatim at the top level of the build file. Handy for guards such as `<error value="..." unless="HXCPP_M64" />`. |

### Variables

These are substituted in every attribute before the module is used:

| Variable | Value |
|---|---|
| `${HLMODULE_DIR}` | Absolute folder of the `hl_module.xml`. |
| `${HLMODULE_NAME}` | The module name. |
| `${HL_FOLDER}` | Target folder (`Windows64`, `Linux64`, `WebAssembly`, ...). |
| `${HL_INCLUDE}` | HashLink headers (`hl.h`). |

The generated build file also defines `HL_FOLDER`, `HL_INCLUDE` and `HLMODULE_<NAME>_DIR` for every module as
hxcpp variables, so one module can refer to another one's folder.

### Paths and conditions

- A relative `name` in `<file>`, `<depend>` or `<lib>`, and a relative `from`/`dir`, is resolved against the
  folder of the `hl_module.xml`. (hxcpp would resolve it against the build directory.) Names that start with
  `-` or `${` are left alone.
- `if` / `unless` on the blocks `hl_compile` handles itself (`<files>`, `<target>`, `<hdlls>`, `<copy>`)
  accept `windows`, `linux`, `mac`, `android`, `ios`, `wasm` (or `emscripten`), `x64`, `x86`, `arm64`, `arm7`
  and any Haxe define, combined with `!`, `&&` and `||`. On the elements *inside* a block they are passed to
  hxcpp, which evaluates them with its own rules.

### Conflicts and rebuilds

- **hdlls.** Roots are searched in order: the project's `hdlls/` first, then modules in class path order. If
  the same library id appears twice, the first one wins and a notice is printed. A static library still wins
  over a dynamic one with the same id, whichever root it comes from.
- **Flags are shared.** All modules' `<files>` go into one `natives` group, so a `-I` or `-D` added by one
  module applies to every native file.
- **Rebuilds.** Changing a module's `hl_module.xml`, its `<file>` sources, its `<copy>` sources or any file in
  its `-I` folders invalidates the "up to date" check. With the compile cache on, module and `natives/` sources are
  cached per file too; when any header in those folders changes, the whole group is compiled again.
- **Haxe side.** A module only adds native code; the Haxe externs live in the library's class path as usual
  (`@:hlNative("my_framework", "fw_answer")` resolves to the C function `my_framework_fw_answer`).
- **Both modes.** In [VM mode](#bytecode-vm-mode) every module that has `<files>` is built into its own
  `<module name>.hdll`, so the module name must match the library name used in `@:hlNative`. Write the native
  code the standard hdll way (below) and the same module works in both modes.

### Example

`my_framework/hl_module.xml`:

```xml
<hlmodule name="my_framework">
  <files>
    <compilerflag value="-I${HLMODULE_DIR}/native" />
    <file name="native/fw.c" />
  </files>
  <copy from="assets" to="assets" />
</hlmodule>
```

`my_framework/native/fw.c`:

```c
#include <hl.h>
int my_framework_fw_answer(void) { return 42; }
```

`my_framework/src/Fw.hx`:

```haxe
class Fw {
	@:hlNative("my_framework", "fw_answer")
	public static function answer():Int { return 0; }
}
```

Building a project that uses `--library my_framework` produces an executable where `Fw.answer()` returns 42
and `build/<target>/assets/` contains the framework's assets.

To make that module work in bytecode mode as well, write `fw.c` the way every HashLink library is written:
`HL_NAME` gives the symbol its library prefix and `DEFINE_PRIM` registers it with its signature.

```c
#define HL_NAME(n) my_framework_##n
#include <hl.h>

HL_PRIM int HL_NAME(fw_answer)(void) { return 42; }
DEFINE_PRIM(_I32, fw_answer, _NO_ARG)
```

In HashLink/C mode this is the function `my_framework_fw_answer` that the generated code calls. In VM mode
`DEFINE_PRIM` exports it from the hdll. `hl_compile` passes `-DHL_COMPILE_HLC` or `-DHL_COMPILE_VM` while
compiling module and `natives/` sources, in case a file needs to tell the modes apart.

## Bytecode (VM) mode

HashLink/C gives the best runtime performance, but every change means compiling the generated C again. For
development it is faster to let Haxe emit bytecode and run it on a VM that is built only once. Selecting it
takes one change in the `.hxml`:

```hxml
--library hl_compile
--hl bin/main.hl        # .hl instead of .c
--main Main
```

```
haxe build.hxml
./bin/build/Linux64/output          # Windows: bin\build\Windows64\output.exe
```

What `hl_compile` does in this mode:

1. Builds the HashLink VM (`libs/<target>/hl[.exe]`) the first time, from the HashLink sources, and caches it
   like the runtime. Delete the file to rebuild it.
2. Copies the VM to `bin/build/<target>/<hl_exe_name>` and the bytecode next to it as `hlboot.dat`. The
   executable looks for `hlboot.dat` in its own folder, so it can be started from any directory. Program
   arguments are passed through.
3. Builds the native code into hdlls, placed next to the executable. Each one is only rebuilt when its own
   sources changed:

   | hdll | Built from |
   |---|---|
   | `hashlinkinjections.hdll` | `@:injectHeaderCode` / `@:injectNativeFunction` ([below](#injecting-native-code-from-haxe)) |
   | `<module name>.hdll` | the `<files>` of each [`hl_module.xml`](#modules-frameworks). Its `<target>` libraries and flags are used to link that hdll. |
   | `natives.hdll` | the project's `natives/` folder (name set with `-D hl_natives_hdll=<name>`) |

4. Copies prebuilt hdlls from `hdlls/dynamic/<target>` and from modules' `<hdlls>` roots, and the modules'
   `<copy>` files, exactly as in HashLink/C mode.

Build-time checks and speed:

- The native table of the bytecode is read after every build. A library the program needs that was neither
  built nor found (`fmt.hdll`, say), or a function an hdll does not export, is reported as a warning instead
  of failing when the program starts. `-D hl_strict_natives` makes it an error.
- hdlls that changed are built at the same time (`-D hl_jobs=<n>`), and the VM executable and `hlboot.dat` are
  only rewritten when their content changed, so a build never touches a program that is running.
- The launcher accepts the VM options `--debug <port>`, `--debug-wait`, `--debug-opt`, `--hot-reload`,
  `--profile <n>` and `--dump` before the program's own arguments.

The project's `natives/` folder also serves the other hdlls of the project, as it serves the executable in
HashLink/C mode: its folder is added to the include path (`-I`) and its static libraries (`.lib`/`.a`) are linked,
even when it has no `.c` file of its own. So injected code can `#include <SDL3/SDL.h>` from `natives/SDL3/` and
call the library. If a library is an import library (`SDL3.lib` for `SDL3.dll`), put the `.dll` in
`hdlls/dynamic/<target>` (or copy it with a module's `<copy>`) so it ends up next to the executable. When both
`hashlinkinjections.hdll` and `natives.hdll` exist, each gets its own copy of the static libraries and their
state, so keep the code that uses one library in a single place.

A module without `<file>` entries (only `<compilerflag>`, `<target>` libraries, `<pkgconfig>`...) has no sources
to build, so what it declares is applied to the hdlls built from the project's injections and `natives/`.

Things that work differently from HashLink/C mode:

- Static libraries (`hdlls/static`, `.a`/`.lib` in `natives/`) cannot be used by a VM: they are ignored, with a
  notice. Link them into one of your own hdlls through a module's `<target>` instead.
- The VM only includes the HashLink core. The standard hdlls of the HashLink repository (`fmt`, `ssl`, `sdl`,
  `uv`, ...) are not built; put prebuilt ones in `hdlls/dynamic/<target>`.
- Native code that calls into the runtime needs the VM to resolve those symbols when it loads the hdll. This is
  handled by the link step; you only write ordinary hdll code with `HL_NAME` and `DEFINE_PRIM`.
- Requires x86-64 (the HashLink JIT). WebAssembly, 32-bit and ARM targets must use `--hl <file>.c`.
- The `hl_unity`, compile cache and `hl_exe_name` options of the C backend do not apply to the bytecode itself;
  `hl_exe_name` still names the executable, and `hl_fast` / `hl_force` apply to the hdlls.

## Injecting native code from Haxe

Two metadata let you write C next to the Haxe code that uses it, with no separate file:

```haxe
@:injectHeaderCode("static int calls = 0;")          // placed after #include <hl.h>
class Inj {
	@:injectNativeFunction("calls++; return name->length * 2 + x + calls;")
	public static function twice(name:String, x:Int):Int { return 0; }   // the Haxe body is not used
}
```

The C code becomes the body of a function whose parameters carry the Haxe names. It is written to
`<output dir>/injections/<Class>/<Class>.c` and compiled with the rest of the native code: into the executable in
HashLink/C mode, into `hashlinkinjections.hdll` in VM mode. The same source works in both modes.

| Haxe type | C type | hdll signature (VM mode) |
|---|---|---|
| `Int` / `Float` / `Single` / `Bool` / `Void` | `int` / `double` / `float` / `bool` / `void` | `_I32` / `_F64` / `_F32` / `_BOOL` / `_VOID` |
| `String` | `vstring*` | `_STRING` |
| `hl.Bytes` | `vbyte*` | `_BYTES` |
| `Dynamic`, `Any` | `vdynamic*` | `_DYN` |
| `Null<Int>`, `Null<Float>`, `Null<Single>`, `Null<Bool>` and optional arguments of those | `vdynamic*` | `_NULL(...)` |
| function types | `vclosure*` | `_FUN(...)` |
| `hl.NativeArray` | `varray*` | `_ARR` |

In VM mode the VM compares the signature with the bytecode and refuses to start on a mismatch, so other types are
rejected at compile time with an explanation. Use `Dynamic` or one of the types above in the signature of an
injected function.

## WebAssembly / Emscripten

### Enabling it

```hxml
--library hl_compile
-D hl_force_webassembly
--hl bin/main.c
--main Main
```

`emcc` must be available (run your emsdk environment script first, e.g. `source emsdk_env.sh`).
The target folder is `WebAssembly`, and the result is:

```
bin/build/WebAssembly/output.js
bin/build/WebAssembly/output.wasm     (written by emcc next to the .js)
```

### What changes compared to a desktop build

| | Desktop | WebAssembly |
|---|---|---|
| Toolchain | MSVC / gcc / clang | `emcc` through hxcpp's emscripten toolchain |
| Runtime | `libhl.dll` (Windows) or static `hl.lib` | static `libs/WebAssembly/hl.a` (`libhl.a` is also accepted) |
| Extra compile flags | — | `-DHL_WEBASM -D_GNU_SOURCE` |
| Link flags | — | `-O3 -s WASM=1 -s ALLOW_MEMORY_GROWTH=1 -s DEFAULT_TO_CXX=1` |
| Native libraries | `.hdll` and/or static | **static only** |

If the runtime archive is missing, it is built automatically the first time (`BuildHashlink.xml` is invoked
with `-Demscripten`), exactly as on desktop.

### Native libraries

A WebAssembly module cannot load `.hdll` files. Build your natives as static libraries and put them in
`hdlls/static/WebAssembly/` (`*.a`, plus `*.deps`). Any `.hdll` found in `hdlls/dynamic/WebAssembly/` is
ignored, with a notice.

Use the `.deps` file to pass Emscripten settings and libraries to the link step, one per line:

```
# glfw_static.deps (WebAssembly)
-sUSE_GLFW=3
```

Because it is a plain forward to the linker, the same mechanism is how you enable settings such as
`-sASYNCIFY` if your program needs them.

### Running

- Console programs: `node bin/build/WebAssembly/output.js`
- Browser: serve the folder over HTTP (a `file://` page cannot fetch the `.wasm`), and load `output.js` from
  an HTML page. Programs that draw need a `<canvas>` element handed to the module as `Module.canvas`.

### Keep in mind

- The browser is single-threaded and event-driven. A Haxe `while (running) { ... }` main loop blocks the tab
  unless the program yields to the browser (Emscripten's main-loop API, or `-sASYNCIFY`). No such flag is
  added for you.
- `-pthread` is not enabled, so programs that spawn HashLink threads will not work.
- OpenGL is WebGL 2 (a GLES 3.0 subset): desktop-GL loaders and `#version 330 core` shaders need adapting
  (`#version 300 es`).
- Emscripten provides its own GLFW implementation (`-sUSE_GLFW=3`), so the desktop GLFW sources are not
  compiled for this target; parts of the API may be missing.

## How it works (backend)

```
Haxe ──► HashLink/C generator ──► main.c + hl/ _std/ ...        (Haxe compiler)
              │
              ▼   onAfterGenerate  (hlcompiler.HlCompiler)
   ┌──────────────────────────────────────────────────────────┐
   │ 1. detect target (OS / arch / WebAssembly)               │
   │ 2. runtime missing? build it: BuildHashlink.xml ──► hxcpp │──► libs/<Os><Arch>/
   │ 3. resolve hdlls/static + hdlls/dynamic                  │
   │ 4. generate Build-<Os><Arch>.xml                         │
   │ 5. hxcpp compiles + links ──► MSVC | gcc/clang | emcc    │──► bin/build/<Os><Arch>/
   │ 6. copy runtime DLL and dynamic hdlls next to the exe    │
   └──────────────────────────────────────────────────────────┘
```

Details:

- **Entry point.** `extraParams.hxml` adds `--macro hlcompiler.HlCompiler.init()` whenever the library is
  used. `init()` detects the target and registers the build step to run when Haxe finishes generating.
- **Compilation unit.** HLC emits a unity `main.c` that `#include`s every generated file and `hlc_main.c`
  (the program entry point). `hl_compile` compiles the top-level `.c` files of the output directory with the
  HashLink headers on the include path (`-std=c11` outside Windows).
- **Runtime build.** `BuildHashlink.xml` is an hxcpp build file that compiles the HashLink runtime
  (`gc.c`, the standard library) and PCRE2 from the bundled sources: as a **DLL on Windows**, as a **static
  archive** everywhere else.
- **Build file generation.** For every build a fresh hxcpp XML (`Build-<Os><Arch>.xml`) is written next to
  the generated C code and handed to `haxelib run hxcpp`, with the right `-D` flags for the OS and
  architecture. hxcpp selects and drives the platform compiler.
- **Linking (per platform).**
  - *Windows:* `libhl.lib` (import library of `libhl.dll`, generated from the DLL's export table), one import
    library per dynamic hdll with `/DELAYLOAD`, static libraries as-is, plus `winmm`, `user32`, `gdi32`,
    `shell32`, `opengl32`.
  - *Linux / macOS:* the whole runtime archive is linked and **exported** from the executable
    (`-rdynamic` / `-export_dynamic`), static libraries follow it and precede the system libraries they
    depend on, dynamic hdlls are linked with `-rpath '$ORIGIN'` so they are found next to the executable.
  - *WebAssembly:* static libraries, then the runtime archive, through `emcc`.
- **Logging.** Every message is prefixed with `[hlcompiler]`. Failures print `[hlcompiler] Error: ...` and
  stop the Haxe build with exit code 1.

## The one-runtime rule

A HashLink process must contain **exactly one** copy of the runtime: one garbage collector, one `hl_setup`,
one set of type tables. If a native library carries its own statically-linked copy, then the moment it calls
back into Haxe (`hl_dyn_call`, `hl_add_root`, ...) it runs against a runtime that was never initialised, and
the program crashes — typically only on Windows and macOS, where a library's symbols do not get interposed
by the executable's, and often *only* when a callback fires, because plain natives never touch the runtime.

`hl_compile` therefore uses this model:

| Platform | Where the single runtime lives | How natives reach it |
|---|---|---|
| Windows | `libhl.dll` | executable and every hdll import `libhl.lib`; static natives link against it |
| Linux / macOS | inside the executable (exported) | hdlls leave `hl_*` undefined and resolve them against the executable |
| WebAssembly | inside the module | everything is one module |

At link time `hl_compile` rejects any `.hdll` that exports runtime symbols (`hl_global_init`, `hl_setup`,
`hl_dyn_call`) with a message explaining how to rebuild it. Use `-D hl_allow_embedded_runtime` to bypass the check.

## Writing native libraries for hl_compile

For your own natives to work with every mode above:

1. **Do not link the HashLink runtime into your library.** On Windows import `libhl.lib`; on Linux/macOS
   leave the symbols undefined (macOS: `-Wl,-undefined,dynamic_lookup`).
2. **Compile against the same `hl.h`** as the bundled runtime (`hashlink/src`).
3. **Offer a static build.** When building statically, do not emit the `hlp_*` lookup tables (they only
   exist for the JIT VM and collide when two static libraries define the same name). `hl_glfw` and `hl_glad`
   do this with a `STATIC_HDLL` define.
4. **Ship a `.deps` file** with every static library, listing the system libraries it needs.
5. **Never let a Haxe exception unwind through foreign frames.** When a native calls a Haxe callback from
   inside another library (window procedures, event loops...), use `hl_dyn_call_safe` and report the
   exception instead of propagating it.

## Troubleshooting

First run `haxelib run hl_compile doctor`: it checks the toolchain and the library and tells you what to fix.

| Message / symptom | Cause and fix |
|---|---|
| Nothing happens, no `[hlcompiler]` lines | The compilation has no `--hl` output, so `hl_compile` has nothing to build. Add `--hl bin/main.c` (HashLink/C) or `--hl bin/main.hl` (bytecode VM). |
| `No .c files found in <dir>` | The `--hl` output does not end in `.c`, so Haxe did not generate HashLink/C. |
| `vswhere.exe not found` / `could not find a Visual Studio installation` | Install Visual Studio or Build Tools with the *Desktop development with C++* workload. |
| `<x>.hdll contains its own copy of the HashLink runtime` | The hdll was built with the runtime linked in. Rebuild it with a current `hl_glfw` / `hl_glad`, or your own library following [the rules](#writing-native-libraries-for-hl_compile). |
| Program starts, then crashes when a callback fires (window resize, key press...) | Two runtimes in the process. Check with `dumpbin /dependents` (Windows) that the executable and every hdll import `libhl.dll`, and that no hdll exports `hl_*`. |
| `libhl.dll` not found when launching the program (Windows) | Run the executable from `build/<Os><Arch>/`, where `hl_compile` copies it; ship the DLL with your program. |
| Error creating files under the haxelib folder | The runtime is built into the library directory, which must be writable (see [Installation](#installation-and-first-build)). |
| Undefined references to `-lm`, `-lGL`, ... on Linux | A static library is missing its `.deps` file, or the file lacks that entry. |
| `hxcpp exited with code N` | The C compiler failed. The lines above the message are hxcpp's and the compiler's own output. |
| Old objects seem to be used after switching hdll mode | Delete `bin/obj`, or rebuild the hdll with the library's own tool, which resets its objects when the mode changes. |

## Limitations

- Not implemented: Windows icon and version resources, AppImage packaging, and a single-file executable for
  bytecode mode. Packaging copies the files of the build folder.
- The standard hdlls of the HashLink repository (`fmt`, `sdl`, `ssl`, `openal`, ...) are not built by this
  library. They are meant to come from separate libraries that ship an `hl_module.xml`.
- Tested on Linux only. Windows (MSVC) and macOS code paths are written against the toolchains but have not
  been run; `.github/workflows/ci.yml` runs `tests/smoke.sh` on all three.

- Two modes: HashLink/C (`--hl file.c`) and bytecode on a precompiled VM (`--hl file.hl`, x86-64 only).
- The native build is incremental: split compilation with a compile cache, and an up-to-date check that skips
  hxcpp when nothing changed (`-D hl_force` rebuilds). In VM mode each hdll has its own check.
- Cross compilation depends on the toolchain you provide; `hl_force_*` only selects the target, it does not
  install one.
- Extra compiler/linker flags cannot be passed through a define. The `.deps` mechanism covers link-time
  needs of native libraries.
- WebAssembly has the constraints listed [above](#keep-in-mind).

## Repository layout

```
hl_compile/
├─ haxelib.json
├─ extraParams.hxml          registers the macro (--macro hlcompiler.HlCompiler.init())
├─ hlcompiler/
│  ├─ HlCompiler.hx          the whole build pipeline (modules, VM mode, hdlls)
│  ├─ HlBytecode.hx          reads the native table of a .hl file
│  ├─ macros/
│  │  └─ NativeExecutionMacro.hx   @:injectHeaderCode / @:injectNativeFunction
│  └─ cli/                   `haxelib run hl_compile` (doctor, build, run, watch, ...)
├─ tests/
│  ├─ smoke.sh               builds tests/smoke in both modes and checks the output
│  └─ smoke/                 a small app, a module (fw/) and a natives/ folder
├─ .github/workflows/ci.yml  runs the smoke test on Linux, Windows and macOS
├─ BuildHashlink.xml         builds the HashLink runtime (DLL on Windows, static elsewhere) and the VM
├─ vm/
│  └─ launcher.c             entry point of the VM executable (finds hlboot.dat next to it)
├─ hashlink/                 HashLink sources (git submodule)
└─ libs/<Os><Arch>/          runtime built on first use (generated, not versioned)
```

## License

`hl_compile` is released under the MIT license. It bundles [HashLink](https://github.com/HaxeFoundation/hashlink)
(MIT) and, through it, PCRE2 (BSD); their licenses are included with their sources under `hashlink/`.
