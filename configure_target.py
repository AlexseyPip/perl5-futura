#!/usr/bin/env python3
"""Turn a same-architecture HOST Perl 5.45.4 config into a FuturaOS config.

Build-time capabilities are verified with the TARGET compiler and TARGET
libraries.  Target executables are *never* executed on the build host.
"""
import argparse
import os
import re
import shlex
import subprocess
import tempfile
from pathlib import Path

# Symbols that correspond to Perl Configure's d_* feature tests.
# We intentionally exclude d_* flags about types, macros, struct fields and
# ABI properties: those cannot be diagnosed by checking for a linker symbol.
SYMBOLS = '''
accept4 access alarm asinh acosh atanh atoll backtrace cbrt chown chroot clearenv closedir copysign copysignl crypt ctermid cuserid difftime dirfd dladdr dlclose dlerror dlopen dlsym dup2 dup3
endgrent endhostent endnetent endprotoent endpwent endservent erf erfc exp2 expm1 fchdir fchmod fchmodat fchown fcntl fdim fdopendir fegetround ffs ffsl finite finitel fma fmax fmin fgetpos flock fork fpathconf frexpl fseeko fsetpos
fsync ftello futimes gai_strerror getaddrinfo getcwd getentropy getgrent getgrgid
getgrnam getgroups gethostbyaddr gethostbyname gethostent gethostname
getitimer getlogin getnameinfo getnetbyaddr getnetbyname getnetent
getpagesize getpgid getpgrp getppid getpriority getprotobyname
getprotobynumber getprotoent getpwent getpwnam getpwuid getservbyname
getservbyport getservent getspnam gettimeofday hasmntopt hypot ilogb ilogbl inet_aton inet_ntop inet_pton kill killpg link localeconv
lchown ldexpl lgamma lgamma_r linkat llrint llrintl llround llroundl lockf log1p log2 logb lround lroundl lrint lrintl lstat madvise malloc_usable_size mblen mbrlen mbrtowc mbstowcs mbtowc memmem memrchr mkdir
mkdtemp mkfifo mkostemp mkstemp mkstemps mktime mmap mprotect msync
munmap nearbyint nanosleep nextafter nexttoward nice nl_langinfo openat opendir pathconf pause pipe pipe2
poll prctl posix_fadvise posix_madvise pread pwrite readlink readv realpath recvfrom
recvmsg regcomp remainder remquo rename renameat rewinddir rint rmdir round sched_yield seekdir select sendmsg
setegid seteuid setgid setgroups setitimer setlocale setpgid setpgrp
setpriority setregid setresgid setresuid setreuid setsid setuid
setenv setgrent sethostent setlinebuf setnetent setprotoent setpwent setservent setvbuf sigaction sigpending sigprocmask sigsuspend sigwait sigwaitinfo
snprintf sockatmark socket socketpair sqrtl stat strcoll strnlen strtod strtol strtoll strtoul strtoull strxfrm statvfs strerror_r strftime strlcat strlcpy
strptime strtold symlink sysconf syscall syslog tcgetpgrp tcsetpgrp telldir tgamma timegm times trunc truncl truncate
ualarm umask uname unlinkat unsetenv usleep utime utimes vsnprintf wait4 waitpid wcrtomb wcscmp wcscoll wcslen wcstombs wcsxfrm
wctomb writev
'''.split()

# The config.sh feature key isn't always the function name.
FEATURE_SYMBOL = {
    'd_gettimeod': 'gettimeofday', 'd_gethname': 'gethostname',
    'd_sockpair': 'socketpair',
    'd_getpagsz': 'getpagesize', 'd_getprior': 'getpriority',
    'd_getgrps': 'getgroups', 'd_gethbyaddr': 'gethostbyaddr',
    'd_gethbyname': 'gethostbyname', 'd_gethent': 'gethostent',
    'd_getpbyname': 'getprotobyname', 'd_getpbynumber': 'getprotobynumber',
    'd_getpent': 'getprotoent', 'd_getsbyname': 'getservbyname',
    'd_getsbyport': 'getservbyport', 'd_getsent': 'getservent',
    'd_getnbyaddr': 'getnetbyaddr', 'd_getnbyname': 'getnetbyname',
    'd_getnent': 'getnetent', 'd_statvfs': 'statvfs',
    'd_fstatvfs': 'fstatvfs', 'd_statfs': 'statfs', 'd_fstatfs': 'fstatfs',
    'd_getitimer': 'getitimer', 'd_sigaction': 'sigaction',
    'd_locconv': 'localeconv', 'd_inetaton': 'inet_aton',
    'd_htonl': 'htonl', 'd_readdir': 'readdir',
    'd_getmntent': 'getmntent', 'd_setprior': 'setpriority',
    'd_setgrps': 'setgroups', 'd_statblks': 'stat',
}

# Perl's Configure feature names -> actual POSIX headers.
HEADERS = {
    'i_arpainet': 'arpa/inet.h', 'i_crypt': 'crypt.h',
    'i_dirent': 'dirent.h', 'i_dlfcn': 'dlfcn.h',
    'i_execinfo': 'execinfo.h', 'i_fcntl': 'fcntl.h',
    'i_fenv': 'fenv.h', 'i_grp': 'grp.h',
    'i_inttypes': 'inttypes.h', 'i_langinfo': 'langinfo.h',
    'i_locale': 'locale.h', 'i_mntent': 'mntent.h',
    'i_netdb': 'netdb.h', 'i_netinettcp': 'netinet/tcp.h',
    'i_niin': 'netinet/in.h', 'i_poll': 'poll.h',
    'i_pthread': 'pthread.h', 'i_pwd': 'pwd.h',
    'i_quadmath': 'quadmath.h', 'i_shadow': 'shadow.h',
    'i_stdbool': 'stdbool.h', 'i_stdckdint': 'stdckdint.h',
    'i_stdint': 'stdint.h', 'i_stdlib': 'stdlib.h',
    'i_sysdir': 'sys/dir.h', 'i_sysfile': 'sys/file.h',
    'i_sysioctl': 'sys/ioctl.h', 'i_syslog': 'syslog.h',
    'i_sysmman': 'sys/mman.h', 'i_sysmount': 'sys/mount.h',
    'i_sysparam': 'sys/param.h', 'i_syspoll': 'sys/poll.h',
    'i_sysrandom': 'sys/random.h', 'i_sysresrc': 'sys/resource.h',
    'i_sysselct': 'sys/select.h', 'i_sysstat': 'sys/stat.h',
    'i_sysstatfs': 'sys/statfs.h', 'i_sysstatvfs': 'sys/statvfs.h',
    'i_syssyscall': 'sys/syscall.h', 'i_systime': 'sys/time.h',
    'i_systimes': 'sys/times.h', 'i_systypes': 'sys/types.h',
    'i_sysuio': 'sys/uio.h', 'i_sysun': 'sys/un.h',
    'i_sysutsname': 'sys/utsname.h', 'i_sysvfs': 'sys/vfs.h',
    'i_syswait': 'sys/wait.h', 'i_termios': 'termios.h',
    'i_time': 'time.h', 'i_unistd': 'unistd.h',
    'i_utime': 'utime.h', 'i_wchar': 'wchar.h',
    'i_wctype': 'wctype.h',
}

# These imply Linux interfaces not supplied by FuturaOS or assumptions which
# are false for its libc.  They are disabled even if the host config says yes.
FORCE_UNDEF = '''
d_flock d_fcntl_can_lock d_prctl d_prctl_set_name d_pthread_atfork
d_getenv_preserves_other_thread d_crypt_r d_getspnam_r d_gnulibc
d_lc_monetary_2008 d_perl_lc_all_uses_name_value_pairs
d_tm_tm_gmtoff d_tm_tm_zone
d_siginfo_si_band d_siginfo_si_errno d_siginfo_si_fd d_siginfo_si_pid
d_siginfo_si_status d_siginfo_si_uid
'''.split()

# Certain attributes are ABI-sensitive and must not come from glibc probes.
# PerlIO handles FILE internals instead.
FORCE_UNDEF += '''
d_stdio_ptr_lval d_stdio_cnt_lval d_stdio_ptr_lval_sets_cnt
d_stdio_ptr_lval_no_undef d_stdio_stream_array d_stdio_cnt_lval_sets_ptr
'''.split()

BASE_EXTENSIONS = '''
Cwd Data/Dumper Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA
Encode Fcntl File/Glob Filter/Util/Call Hash/Util Hash/Util/FieldHash
IO List/Util MIME/Base64 Math/BigInt/FastCalc Opcode POSIX
PerlIO/encoding PerlIO/mmap PerlIO/via SDBM_File Socket Storable
Time/HiRes Time/Piece Unicode/Normalize attributes mro re
'''.split()

MANDATORY = {'fork', 'waitpid', 'open', 'close', 'read', 'write', 'lseek',
             'stat', 'fstat', 'opendir', 'readdir', 'getcwd', 'malloc',
             'free', 'getenv', 'sigaction', 'mmap', 'munmap', 'dlopen',
             'dlsym', 'dlclose', 'dlerror'}

PATTERN = re.compile(r"^([A-Za-z_][A-Za-z_0-9]*)=(.*)$")

def parse_values(content):
    result = {}
    for line in content.splitlines():
        m = PATTERN.match(line)
        if not m:
            continue
        key, value = m.groups()
        if value.startswith("'") and value.endswith("'") and "'" not in value[1:-1]:
            result[key] = value[1:-1]
        else:
            result[key] = value
    return result

def quote_shell(value):
    return "'" + str(value).replace("'", "'\\''") + "'"

def edit_config(content, changes):
    output = []
    seen = set()
    for line in content.splitlines(keepends=True):
        match = PATTERN.match(line.rstrip('\n'))
        if match and match.group(1) in changes:
            k = match.group(1)
            output.append(k + '=' + quote_shell(changes[k]) + '\n')
            seen.add(k)
        else:
            output.append(line)
    for key, value in changes.items():
        if key not in seen:
            output.append(key + '=' + quote_shell(value) + '\n')
    return ''.join(output)

def run_probe(cmd, source, tmpdir, link=False, libraries=None):
    out = Path(tmpdir) / ('probe' if link else 'probe.o')
    extra = [] if link else ['-c']
    proc = subprocess.run(cmd + ['-x', 'c', '-'] + extra + ['-o', str(out)] + (['-x', 'none'] + libraries if libraries else []),
                          input=source, encoding='utf-8',
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode == 0, proc.stderr

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', type=Path, required=True)
    ap.add_argument('--root', type=Path, required=True)
    ap.add_argument('--hostperl', type=Path, required=True)
    ap.add_argument('--hostgenerate', type=Path, required=True)
    ap.add_argument('--cc', required=True)
    ap.add_argument('--ar', required=True)
    ap.add_argument('--ranlib', required=True)
    ap.add_argument('--nm', required=True)
    ap.add_argument('--jobs', type=int, default=2)
    args = ap.parse_args()
    root = args.root.resolve()
    cfg = args.config.read_text()
    old = parse_values(cfg)
    target_cc = shlex.split(args.cc)
    if not target_cc:
        raise SystemExit('Missing target C compiler')
    sysincludes = [root / 'include', root / 'base/usr/include']
    for p in sysincludes:
        if not p.is_dir():
            raise SystemExit(f'Missing FuturaOS headers: {p}')
    libs = [root / 'base/lib', root / 'base/usr/lib']
    if not any((p / 'libc.so').is_file() or (p / 'libc.a').is_file() for p in libs):
        raise SystemExit('Missing FuturaOS libc under base/lib or base/usr/lib; build libc first.')
    if not any((p / 'libm.so').is_file() or (p / 'libm.a').is_file() for p in libs):
        raise SystemExit('Missing FuturaOS libm under base/lib or base/usr/lib; build libm first.')
    cflags = ['-O2', '-fwrapv', '-fno-strict-aliasing', '-fPIC',
              '-D_LARGEFILE_SOURCE', '-D_FILE_OFFSET_BITS=64']
    # Perl's genuine socketpair emulation uses INADDR_LOOPBACK. FuturaOS
    # currently omits this standard constant from arpa/inet.h; supply only
    # the missing constant to target Perl (not a fake socketpair function).
    cflags += ['-DINADDR_LOOPBACK=0x7f000001UL']
    cflags += [f'-I{p}' for p in sysincludes]
    lflags = [f'-L{p}' for p in libs] + ['-Wl,-rpath,/lib',
               '-Wl,-rpath,/usr/lib', '-Wl,-z,max-page-size=0x1000',
               '-Wl,--allow-shlib-undefined']
    target_libs = ['-ldl', '-lm', '-lc']

    changes = {
        'osname': 'futura', 'osvers': '1', 'myuname': 'FuturaOS x86_64',
        'archname': 'x86_64-futura', 'targetarch': 'x86_64-pc-toaru',
        'usecrosscompile': 'define', 'hostosname': 'linux',
        'hostperl': str(args.hostperl.resolve()),
        'hostgenerate': str(args.hostgenerate.resolve()),
        'cc': args.cc, 'ld': args.cc,
        'ar': args.ar, 'ranlib': args.ranlib, 'nm': args.nm,
        'ccflags': ' '.join(cflags), 'cppflags': ' '.join(cflags),
        'cccdlflags': '-fPIC', 'ccdlflags': '-Wl,-E',
        'ldflags': ' '.join(lflags + ['-Wl,--export-dynamic']),
        'lddlflags': ' '.join(['-shared', '-fPIC'] + lflags + ['-lm']),
        'libs': ' '.join(target_libs), 'perllibs': ' '.join(target_libs),
        'libswanted': 'dl m c', 'cryptlib': '',
        'incpth': ' '.join(map(str, sysincludes)),
        'usrinc': str(root / 'include'),
        'libpth': ' '.join(map(str, libs)),
        'prefix': '/usr', 'installprefix': '/usr',
        'bin': '/usr/bin', 'scriptdir': '/usr/bin',
        'installbin': '/usr/bin', 'installscript': '/usr/bin',
        # The *_EXP variables are NOT derived from their unexpanded peers
        # when Configure -S reads an existing config.sh.  Leaving the Linux
        # host values here embeds x86_64-linux into the FuturaOS Perl binary's
        # default @INC, even when installperl uses x86_64-futura.  Every
        # compiled-in runtime path must match the staged install layout.
        'privlib': '/usr/lib/perl5/5.45.4',
        'privlibexp': '/usr/lib/perl5/5.45.4',
        'archlib': '/usr/lib/perl5/5.45.4/x86_64-futura',
        'archlibexp': '/usr/lib/perl5/5.45.4/x86_64-futura',
        'installprivlib': '/usr/lib/perl5/5.45.4',
        'installarchlib': '/usr/lib/perl5/5.45.4/x86_64-futura',
        'sitelib': '/usr/lib/perl5/site_perl/5.45.4',
        'sitelibexp': '/usr/lib/perl5/site_perl/5.45.4',
        'sitelib_stem': '/usr/lib/perl5/site_perl',
        'sitearch': '/usr/lib/perl5/site_perl/5.45.4/x86_64-futura',
        'sitearchexp': '/usr/lib/perl5/site_perl/5.45.4/x86_64-futura',
        'installsitelib': '/usr/lib/perl5/site_perl/5.45.4',
        'installsitearch': '/usr/lib/perl5/site_perl/5.45.4/x86_64-futura',
        # No alternate host installation trees may leak in through version
        # compatibility paths. They can be enabled deliberately later.
        'd_archlib': 'define', 'd_sitearch': 'define',
        'inc_version_list': ' ', 'inc_version_list_init': '0',
        'd_inc_version_list': 'undef',
        'useithreads': 'undef', 'usemultiplicity': 'undef',
        'useshrplib': 'false', 'usedl': 'define', 'useperlio': 'define',
        'use64bitint': 'define', 'use64bitall': 'define',
        'usequadmath': 'undef', 'i_quadmath': 'undef',
        'd_fcntl_can_lock': 'undef',
        'd_flock': 'undef', # libc/sys/flock.c returns success without locking!
        'd_sem': 'undef', 'd_msg': 'undef', 'd_shm': 'undef',
        'd_msgget': 'undef', 'd_msgsnd': 'undef', 'd_msgrcv': 'undef',
        'd_msgctl': 'undef', 'd_semget': 'undef', 'd_semop': 'undef',
        'd_semctl': 'undef', 'd_shmget': 'undef', 'd_shmat': 'undef',
        'd_shmdt': 'undef', 'd_shmctl': 'undef',
        'selectminbits': '64',
        'perl': str(args.hostperl.resolve()),
        'run': '', 'to': ':', 'from': ':',
        'static_ext': '',
        'dynamic_ext': ' '.join(BASE_EXTENSIONS),
        'optimize': '-O2', 'ccname': 'gcc',
        'gccversion': '', 'glibc_version': '', 'gnulibc_version': '',
        'libc': '/lib/libc.so',
        'hint': 'futura-port',
    }
    for name in FORCE_UNDEF:
        changes[name] = 'undef'
    # No system headers or linker support can be assumed from Linux host.
    tested = []
    missing = []
    compile_cmd = target_cc + cflags
    with tempfile.TemporaryDirectory(prefix='futura-perl-probes-') as tmp:
        if not run_probe(compile_cmd, '#include <stdio.h>\nint main(void){return 0;}\n', tmp)[0]:
            raise SystemExit('Cannot compile with FuturaOS headers using ' + args.cc)
        for flag, hdr in HEADERS.items():
            if old.get(flag) != 'define' and flag != 'i_fcntl':
                continue
            success, _ = run_probe(compile_cmd, f'#include <{hdr}>\nint main(void){{return 0;}}\n', tmp)
            changes[flag] = 'define' if success else 'undef'
            if not success: missing.append(hdr)
        # Link-only tests: the target program is NOT executed on WSL.
        link_cmd = target_cc + cflags + lflags
        def symbol_exists(name):
            # Compile and link in one call, with the proper target libraries.
            if name in ('stat', 'lstat', 'fstat'):
                # FuturaOS's sys/stat.h gives these functions ABI linker
                # aliases (__statns / __lstatns / __fstatns).  A probe that
                # guesses the ELF symbol name would incorrectly fail.
                arg = '0' if name == 'fstat' else '"/"'
                code = ('#include <sys/stat.h>\n'
                        'int main(void){ struct stat s; return '+name+'('+arg+', &s); }\n')
            else:
                code = ('extern void ' + name + '(void);\n'
                        'int main(void){ void (*volatile p)(void) = &'+name+'; return p == 0; }\n')
            return run_probe(link_cmd + ['-Wl,--no-as-needed'],
                             code, tmp, link=True, libraries=target_libs)[0]
        for symbol in sorted(MANDATORY):
            if not symbol_exists(symbol):
                raise SystemExit(f'Missing REQUIRED FuturaOS libc symbol: {symbol} (check target libraries/toolchain)')
        for symbol in SYMBOLS:
            feature = 'd_' + symbol
            if feature not in old or old[feature] != 'define':
                continue
            if feature in FORCE_UNDEF:
                continue
            yes = symbol_exists(symbol)
            changes[feature] = 'define' if yes else 'undef'
            tested.append((feature, yes))
        for feature, symbol in FEATURE_SYMBOL.items():
            if old.get(feature) != 'define' or feature in FORCE_UNDEF:
                continue
            yes = symbol_exists(symbol)
            changes[feature] = 'define' if yes else 'undef'
            tested.append((feature, yes))
    # The Linux host sets d_sockpair=define. FuturaOS's sys/socket.h does
    # not declare socketpair and libc does not provide it.  Don't let a
    # link-only symbol probe accidentally accept an implicit declaration.
    # Disable the feature unless an actual target-header call compiles AND
    # links. Without it Perl uses its genuine TCP loopback emulation.
    with tempfile.TemporaryDirectory(prefix='futura-perl-socketpair-') as tmp:
        socketpair_test = (
            '#include <sys/types.h>\n'
            '#include <sys/socket.h>\n'
            'int main(void) { int p[2]; return socketpair(AF_UNIX, SOCK_STREAM, 0, p); }\n'
        )
        socketpair_ok, _ = run_probe(
            target_cc + cflags + ['-Werror=implicit-function-declaration'] + lflags,
            socketpair_test, tmp, link=True, libraries=target_libs
        )
        changes['d_sockpair'] = 'define' if socketpair_ok else 'undef'
    if not socketpair_ok:
        print('socketpair(): missing in target libc; using Perl native socketpair emulation.')
    # readv/writev use <sys/uio.h> which is missing in this ABI.
    if changes.get('i_sysuio') == 'undef':
        changes['d_readv'] = changes['d_writev'] = 'undef'
    # Optional XS extensions may be independently enabled later.  In
    # particular Compress::Raw::* needs libs not bundled with FuturaOS.
    # Do not enable glibc's Linux-specific statfs types based on HOST tests.
    if changes.get('i_sysstatfs') == 'undef':
        changes['d_statfs'] = changes['d_fstatfs'] = 'undef'
    if changes.get('i_sysstatvfs') == 'undef':
        changes['d_statvfs'] = changes['d_fstatvfs'] = 'undef'
    # Host uses glibc locale ABI, which is not interchangeable with FuturaOS.
    for k in ('d_newlocale', 'd_uselocale', 'd_duplocale', 'd_freelocale',
              'd_querylocale', 'd_nl_langinfo_l', 'd_strerror_l',
              'd_strxfrm_l', 'd_strcoll_l', 'd_wcsxfrm_l', 'd_wcscol_l'):
        if old.get(k) == 'define':
            changes[k] = 'undef'
    # libc's advisory-lock API is explicitly not implemented.
    args.config.write_text(edit_config(cfg, changes))
    print(f'Configured Perl 5.45.4 for FuturaOS (probed {len(tested)} optional symbols)')
    print(f'Unavailable target headers: {", ".join(missing) or "none"}')
    print('Disabled optional library calls:',
          ', '.join(flag for flag, ok in tested if not ok) or 'none')
    print('Default XS modules:', ' '.join(BASE_EXTENSIONS))

if __name__ == '__main__':
    main()
