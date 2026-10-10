#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN32
#	include <windows.h>
#	include <wchar.h>
typedef wchar_t pch;
#	define PS(s) L##s
#	define PEQ(a, b) (wcscmp((a), (b)) == 0)
#	define PLEN(s) wcslen(s)
#	define PCPY(d, s) wcscpy((d), (s))
#	define ENTRY wmain
#else
#	include <unistd.h>
#	ifdef __APPLE__
#		include <mach-o/dyld.h>
#	endif
typedef char pch;
#	define PS(s) s
#	define PEQ(a, b) (strcmp((a), (b)) == 0)
#	define PLEN(s) strlen(s)
#	define PCPY(d, s) strcpy((d), (s))
#	define ENTRY main
#endif

extern int hl_vm_main(int argc, pch *argv[]);

#define BOOT_FILE PS("hlboot.dat")
#define PATH_MAX_LEN 4096

static int boot_path(pch *out) {
	size_t n;
#	ifdef _WIN32
	n = GetModuleFileNameW(NULL, out, PATH_MAX_LEN - 16);
	if (n == 0 || n >= PATH_MAX_LEN - 16)
		return 0;
#	elif defined(__APPLE__)
	uint32_t size = PATH_MAX_LEN - 16;
	if (_NSGetExecutablePath(out, &size) != 0)
		return 0;
	n = strlen(out);
#	else
	ssize_t r = readlink("/proc/self/exe", out, PATH_MAX_LEN - 16);
	if (r <= 0)
		return 0;
	n = (size_t)r;
	out[n] = 0;
#	endif
	while (n > 0 && out[n - 1] != PS('/') && out[n - 1] != PS('\\'))
		n--;
	PCPY(out + n, BOOT_FILE);
	return 1;
}

int ENTRY(int argc, pch *argv[]) {
	static pch path[PATH_MAX_LEN];
	pch **nargv = (pch **)malloc(sizeof(pch *) * (argc + 2));
	int i = 0, o = 0;

	if (nargv == NULL)
		return 1;

	if (!boot_path(path))
		PCPY(path, BOOT_FILE);

	nargv[o++] = argv[i++];

	while (i < argc) {
		if ((PEQ(argv[i], PS("--debug")) || PEQ(argv[i], PS("--profile"))) && i + 1 < argc) {
			nargv[o++] = argv[i++];
			nargv[o++] = argv[i++];
		} else if (PEQ(argv[i], PS("--debug-wait")) || PEQ(argv[i], PS("--debug-opt")) || PEQ(argv[i], PS("--hot-reload"))
			|| PEQ(argv[i], PS("--dump"))) {
			nargv[o++] = argv[i++];
		} else {
			break;
		}
	}

	nargv[o++] = path;
	while (i < argc)
		nargv[o++] = argv[i++];
	nargv[o] = NULL;

	return hl_vm_main(o, nargv);
}
