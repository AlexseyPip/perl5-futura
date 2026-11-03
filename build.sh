#!/usr/bin/env bash
# Standalone Perl 5.45.4 cross-build for FuturaOS.
# Usage: bash third_party/perl/build.sh [install|build|clean|diagnose|sources]
# This script intentionally does not run or modify the root Makefile.
# WSL builds on /mnt/c use a symlinked .work to fast ext4 by default.
set -Eeuo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$here/../.." && pwd -P)
archive="$here/perl5-5.45.4.zip"
# On WSL, the Windows-mounted /mnt/c filesystem makes Perl's thousands of
# small source files and Perl Configure's many probes extremely slow. Keep the
# entire port in third_party/perl, but make .work a symlink to a persistent
# native-Linux filesystem cache. PERL5_WORKDIR overrides this completely.
work_path=${PERL5_WORKDIR:-"$here/.work"}
max_jobs=${PERL5_MAX_JOBS:-8}
jobs=${JOBS:-$(nproc 2>/dev/null || printf '2')}

fail() { printf '\nPerl5/FuturaOS: %s\n' "$*" >&2; exit 1; }
info() { printf '\n[perl5] %s\n' "$*"; }

# Inspect an existing failed build without rebuilding anything. GNU make can
# fail in a recipe or Perl code-generator without ever printing GCC's "error:".
# Always include the end of the log, not only compiler-diagnostic matches.
show_make_failure() {
  local log=$1
  if [[ ! -f $log ]]; then
    printf '[perl5] Log does not exist: %s\n' "$log" >&2
    return 1
  fi
  printf '\n[perl5] First errors and failed recipes:\n' >&2
  grep -nE -m 30 \
    '(fatal error:|error:|undefined reference|No rule to make target|(^|[[:space:]])Error [0-9]+|\*\*\*|Permission denied|command not found|not found|No such file or directory|Segmentation fault|Traceback|Can.t locate|Failed|failed|Stop\.)' \
    "$log" >&2 || true
  printf '\n[perl5] Last 120 lines (including failures that do not say error:):\n' >&2
  tail -n 120 -- "$log" >&2
  printf '\n[perl5] Full log: %s\n' "$log" >&2
}

[[ $jobs =~ ^[1-9][0-9]*$ && $max_jobs =~ ^[1-9][0-9]*$ ]] || fail 'JOBS and PERL5_MAX_JOBS must be positive integers'
if (( jobs > max_jobs )); then jobs=$max_jobs; fi

case ${1:-install} in
  clean)
    [[ -n $work_path && $work_path != / && $work_path != . ]] || fail "Unsafe build directory: $work_path"
    if [[ -L $work_path ]]; then
      # Don't follow an arbitrary symlink when cleaning up.
      work_real=$(readlink -f -- "$work_path") || fail "Cannot resolve $work_path"
      [[ -f "$work_real/.futura-perl-build-cache" ]] || fail "Refusing to delete unrecognized symlink target: $work_real"
      rm -rf -- "$work_real"
      rm -f -- "$work_path"
    elif [[ -d $work_path ]]; then
      rm -rf -- "$work_path"
    fi
    info 'Build cache removed (installed base/usr files were NOT removed).'
    exit 0
    ;;
  build|install|diagnose|sources) ;;
  *) fail 'Usage: build.sh [install|build|clean|diagnose|sources]' ;;
esac

# Opt out with PERL5_DISABLE_FAST_WORKDIR=1. Other locations stay untouched.
if [[ -z ${PERL5_WORKDIR:-} && ${PERL5_DISABLE_FAST_WORKDIR:-0} != 1 &&
      $here == /mnt/?/* && ( -n ${WSL_DISTRO_NAME:-} || $(cat /proc/sys/kernel/osrelease 2>/dev/null) == *[Mm]icrosoft* ) ]]; then
  path_key=$(printf '%s' "$here" | sha256sum | cut -c1-16)
  cache_base=${XDG_CACHE_HOME:-"$HOME/.cache"}
  fast_work="$cache_base/futuraos-perl-5.45.4/$path_key"
  mkdir -p -- "$fast_work"
  touch "$fast_work/.futura-perl-build-cache"
  if [[ -d $work_path && ! -L $work_path ]]; then
    # An earlier port created .work on NTFS. Don't destroy that data; move it
    # out of the active build path without reusing stale absolute Make paths.
    backup="$here/.work.ntfs-backup"
    if [[ -e $backup ]]; then backup="$backup.$(date +%s)"; fi
    mv -- "$work_path" "$backup"
    info "Archived old slow /mnt/c cache: $backup"
  fi
  if [[ ! -e $work_path && ! -L $work_path ]]; then
    if ! ln -s -- "$fast_work" "$work_path"; then
      info 'WSL mount does not allow symlinks; falling back to local .work'
      if [[ -n ${backup:-} && -d $backup ]]; then
        mv -- "$backup" "$work_path"
      else
        mkdir -p -- "$work_path"
      fi
    fi
  fi
fi
mkdir -p -- "$work_path"
work=$(cd -- "$work_path" && pwd -P)
source_host="$work/perl5-host"
source_target="$work/perl5-target"

# Always expose the exact (editable!) build source trees in third_party/perl.
# The relative symlinks follow .work even when it points into fast WSL ext4.
# Never copy sources back to /mnt/c: that would create a second, stale tree.
show_source_links() {
  local name target link existing
  for name in src host-src; do
    if [[ $name == src ]]; then
      target='.work/perl5-target'
      [[ -z ${PERL5_WORKDIR:-} ]] || target="$source_target"
    else
      target='.work/perl5-host'
      [[ -z ${PERL5_WORKDIR:-} ]] || target="$source_host"
    fi
    link="$here/$name"
    if [[ -e $link && ! -L $link ]]; then
      info "Keeping existing non-symlink $link untouched (use $target for active sources)"
      continue
    fi
    existing=''
    if [[ -L $link ]]; then existing=$(readlink -- "$link"); fi
    if [[ $existing != "$target" ]]; then
      if [[ -L $link ]]; then rm -f -- "$link"; fi
      if ! ln -s -- "$target" "$link"; then
        info "Cannot create source link $link; use $here/$target"
        continue
      fi
    fi
  done
  printf '[perl5] Active FuturaOS Perl sources: %s\n' "$source_target"
  printf '[perl5] Source alias in project:   %s\n' "$here/src"
  printf '[perl5] Native host helpers:       %s\n' "$source_host"
}

info "Using build cache: $work (parallel jobs: $jobs)"
if [[ ${1:-install} == sources ]]; then
  [[ -f "$source_target/Configure" ]] || fail 'Sources not yet extracted; run install or build once first.'
  show_source_links
  exit 0
fi
if [[ ${1:-install} == diagnose ]]; then
  show_make_failure "$work/target-make.log"
  exit 0
fi
[[ -f "$archive" ]] || fail "Expected upstream source archive at: $archive"
[[ -d "$root/include" && -d "$root/base" ]] || fail 'Run from a complete FuturaOS checkout (include/, base/ must exist).'
command -v python3 >/dev/null || fail 'Python 3 required on WSL build host.'
command -v make >/dev/null || fail 'make required on WSL build host.'
command -v gcc >/dev/null || fail 'Native GCC required to build version-matched host miniperl.'

# The root Makefile normally obtains this exact PATH from util/activate.sh.
# Use it when available, but do not require a top-level make invocation.
if [[ -x "$root/util/activate.sh" ]]; then
  toolpath=$(cd "$root" && util/activate.sh) || fail 'util/activate.sh failed'
  [[ -z $toolpath ]] || export PATH="$toolpath:$PATH"
fi
cc=${PERL5_CC:-x86_64-pc-toaru-gcc}
ar=${PERL5_AR:-x86_64-pc-toaru-ar}
nm=${PERL5_NM:-x86_64-pc-toaru-nm}
ranlib=${PERL5_RANLIB:-x86_64-pc-toaru-ranlib}
for tool in "$cc" "$ar" "$nm" "$ranlib"; do
  command -v "$tool" >/dev/null || fail "Target tool not on PATH: $tool"
done

# Configure's config.sh/Makefile.SH use shell interpolation.  Avoid
# producing invalid commands when invoked from a path with shell whitespace.
if [[ "$root" == *" "* || "$work" == *" "* || "$root" == *"'"* || "$work" == *"'"* ]]; then
  fail 'Please use a project/build path without spaces or apostrophes for Perl upstream Configure.'
fi

# The tarball/zip contains upstream sources only; no network traffic.
# Two source trees are required: host helper programs use Linux ABI while
# the target interpreter and XS extensions must use FuturaOS ABI.
mkdir -p -- "$work"
archive_hash=$(sha256sum "$archive" | awk '{print $1}')
if [[ ! -f "$work/archive.sha256" ]] || [[ $(cat "$work/archive.sha256") != "$archive_hash" ]]; then
  info 'Extracting exact uploaded Perl 5.45.4 sources for host and target'
  rm -rf -- "$source_host" "$source_target"
  python3 - "$archive" "$work" <<'PY'
import pathlib, sys, zipfile
source = pathlib.Path(sys.argv[1]); parent = pathlib.Path(sys.argv[2]);
for dest in ('perl5-host', 'perl5-target'):
    target = parent / dest
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as z:
        for info in z.infolist():
            p = pathlib.PurePosixPath(info.filename)
            if not p.parts or p.parts[0] != 'perl5-5.45.4' or '..' in p.parts:
                raise SystemExit('Unexpected source archive layout: ' + info.filename)
            relative = p.parts[1:]
            if not relative: continue
            out = target.joinpath(*relative)
            if info.is_dir():
                out.mkdir(parents=True, exist_ok=True)
            else:
                out.parent.mkdir(parents=True, exist_ok=True)
                with z.open(info) as infile, open(out, 'wb') as outfile:
                    import shutil
                    shutil.copyfileobj(infile, outfile)
                if info.external_attr >> 16 & 0o111:
                    out.chmod(out.stat().st_mode | 0o111)
PY
  printf '%s\n' "$archive_hash" > "$work/archive.sha256"
fi
[[ -f "$source_host/Configure" && -f "$source_target/Configure" ]] || fail 'Source archive extraction failed.'
show_source_links

# Host miniperl runs build-time Perl code generators. It is NOT installed
# to FuturaOS and is NEVER linked into the target binary.
if [[ ! -x "$source_host/miniperl" || ! -x "$source_host/generate_uudmap" ]]; then
  info 'Configuring and building native host miniperl (version 5.45.4)'
  ( cd "$source_host"
    sh ./Configure -des -Dusedevel -Dcc=gcc -Dld=gcc \
      -Uuseithreads -Uuseshrplib -Dprefix=/usr >"$work/host-configure.log" 2>&1 \
      || { tail -60 "$work/host-configure.log"; exit 1; }
    make -j"$jobs" miniperl generate_uudmap >"$work/host-make.log" 2>&1 \
      || { tail -90 "$work/host-make.log"; exit 1; }
  )
fi
[[ -x "$source_host/miniperl" && -x "$source_host/generate_uudmap" ]] || fail 'Host Perl build did not produce the generator binaries.'

config_stamp=$(
  { printf '%s\n' "$archive_hash" "$cc" "$ar" "$nm" "$ranlib" "$root";
    sha256sum "$here/configure_target.py";
    for hdr in sys/stat.h sys/socket.h setjmp.h signal.h grp.h; do
      test ! -f "$root/include/$hdr" || sha256sum "$root/include/$hdr";
    done
    # Re-probe optional libc symbols after the installed FuturaOS libc changes.
    # Hashing a couple of local libraries is negligible compared with 232
    # target compiler/linker probes; it avoids persisting false d_getgrnam.
    for lib in lib/libc.so lib/libm.so; do
      test ! -f "$root/base/$lib" || sha256sum "$root/base/$lib";
    done
  } | sha256sum | awk '{print $1}'
)
if [[ ! -f "$work/target-configured.sha256" ]] || [[ $(cat "$work/target-configured.sha256") != "$config_stamp" ]]; then
  info 'Preparing target config.sh from same-version host config, probing FuturaOS symbols'
  [[ -f "$source_host/config.sh" ]] || fail 'Host Configure did not produce config.sh'
  cp "$source_host/config.sh" "$source_target/config.sh"
  python3 "$here/configure_target.py" \
    --config "$source_target/config.sh" \
    --root "$root" --hostperl "$source_host/miniperl" \
    --hostgenerate "$source_host/generate_uudmap" \
    --cc "$cc" --ar "$ar" --nm "$nm" --ranlib "$ranlib" \
    --jobs "$jobs" | tee "$work/target-configure.log"
  ( cd "$source_target"
    sh ./Configure -S >"$work/target-regenerate.log" 2>&1 \
      || { tail -90 "$work/target-regenerate.log"; exit 1; }
  )
  printf '%s\n' "$config_stamp" > "$work/target-configured.sha256"
fi

# Critical Perl Configure detail: "Configure -S" runs .SH substitutions but
# its extraction stage keeps an existing config.h.  Incremental builds can
# therefore have d_sigsetjmp='undef' in config.sh while stale config.h still
# defines HAS_SIGSETJMP; every .c then fails on unknown sigjmp_buf.  Generate
# a fresh header into a temporary file and replace the real one ONLY if its
# contents differ, preserving incremental-build object timestamps otherwise.
# This operation is cheap, and does NOT re-run host Configure or 232 probes.
[[ -f "$source_target/config.sh" ]] || fail 'Missing target config.sh'
[[ -f "$source_target/config_h.SH" ]] || fail 'Missing Perl config_h.SH'

# Defensive compatibility check for caches produced by older port scripts:
# a false host d_sigsetjmp='define' must not survive if the target ABI lacks
# sigjmp_buf.  Probe only the type and function declaration, no linking.
if grep -qx "d_sigsetjmp='define'" "$source_target/config.sh"; then
  if ! printf '#include <setjmp.h>\nstatic sigjmp_buf env;\nint main(void) { return sigsetjmp(env, 1); }\n' \
    | "$cc" -std=gnu11 -Werror=implicit-function-declaration \
      -I"$root/include" -I"$root/base/usr/include" -x c -c -o /dev/null - >/dev/null 2>&1; then
    info 'Correcting stale Linux d_sigsetjmp=define in target config.sh'
    sed -i "s/^d_sigsetjmp='define'$/d_sigsetjmp='undef'/" "$source_target/config.sh"
  fi
fi

fresh_header=$(mktemp "$source_target/.config.h.futura.XXXXXX")
if ! ( cd "$source_target" && CONFIG_SH=config.sh CONFIG_H="$fresh_header" \
       sh ./config_h.SH >"$work/target-config-h.log" 2>&1 ); then
  rm -f -- "$fresh_header"
  tail -60 "$work/target-config-h.log" >&2 || true
  fail 'Could not regenerate target config.h'
fi
if [[ ! -f "$source_target/config.h" ]] || ! cmp -s -- "$fresh_header" "$source_target/config.h"; then
  mv -f -- "$fresh_header" "$source_target/config.h"
  info 'Updated stale target config.h from config.sh (preserved source/object cache)'
else
  rm -f -- "$fresh_header"
fi

# Verify the generated header, not just the value in config.sh.  There must
# be NO active HAS_SIGSETJMP define on a libc that has only jmp_buf.
if grep -qx "d_sigsetjmp='undef'" "$source_target/config.sh"; then
  if grep -Eq '^[[:space:]]*#define[[:space:]]+HAS_SIGSETJMP([[:space:]]|$)' "$source_target/config.h"; then
    fail 'Generated config.h still incorrectly enables HAS_SIGSETJMP'
  fi
fi

# Refuse to build a binary with host Linux directories compiled into @INC.
# Perl stores expanded paths separately from the install paths; a successful
# install by itself does not mean the interpreter will find the installed XS.
expected_arch='/usr/lib/perl5/5.45.4/x86_64-futura'
expected_sitearch='/usr/lib/perl5/site_perl/5.45.4/x86_64-futura'
for expected in \
  "archlibexp='$expected_arch'" \
  "sitearchexp='$expected_sitearch'" \
  "privlibexp='/usr/lib/perl5/5.45.4'" \
  "sitelibexp='/usr/lib/perl5/site_perl/5.45.4'"; do
  if ! grep -Fxq -- "$expected" "$source_target/config.sh"; then
    fail "Wrong runtime Perl path in config.sh: expected $expected"
  fi
done
if ! grep -Fq "#define ARCHLIB_EXP \"$expected_arch\"" "$source_target/config.h"; then
  fail "config.h does not contain FuturaOS ARCHLIB_EXP; cannot build a usable @INC"
fi
if ! grep -Fq "#define SITEARCH_EXP \"$expected_sitearch\"" "$source_target/config.h"; then
  fail "config.h does not contain FuturaOS SITEARCH_EXP; cannot build a usable @INC"
fi

# ExtUtils::MakeMaker's generated Makefile has an unusual behaviour: when
# config.sh / Config.pm / Makefile.PL changes, its Makefile target rebuilds
# itself, prints "Your Makefile has been rebuilt", then executes $(FALSE).
# Thus GNU make exits 1 BY DESIGN. A top-level make -j all can encounter this
# in dozens of XS directories after a libc/configuration update. Restart the
# incremental build only for that exact condition, not for compiler errors.
run_target_make() {
  local max_restarts=${PERL5_MAKEFILE_RESTARTS:-8}
  local attempt=1
  local log="$work/target-make.log"
  [[ $max_restarts =~ ^[0-9]+$ ]] || fail 'PERL5_MAKEFILE_RESTARTS must be a non-negative integer'
  while :; do
    # Perl's cross-build Makefile has an rm+ln symlink recipe for the native
    # generate_uudmap and miniperl helpers. Recursive/parallel make can race
    # between deleting and recreating the same link. GNU ln -sfn is safe to
    # re-run when the link already exists; MAKEFLAGS propagates LNS to submakes.
    if ( cd "$source_target" && PERL5LIB="$host_perl5lib" \
         make -j"$jobs" LNS='ln -sfn' RUN_PERL="$host_perl" HOST_PERL="$host_perl" all >"$log" 2>&1 ); then
      return 0
    fi

    # A real compiler, linker, Makefile.PL or code-generator failure must
    # remain visible immediately; don't hide it in the retry loop.
    if grep -Eq '(fatal error:|(^|[[:space:]])error:|undefined reference|collect2: error|No rule to make target|cannot find -l|command not found|Can.t locate|Permission denied|Segmentation fault|Traceback)' "$log"; then
      show_make_failure "$log"
      return 1
    fi
    if ! grep -qF 'Makefile out-of-date with respect to' "$log" ||
       ! grep -qF 'Your Makefile has been rebuilt' "$log"; then
      show_make_failure "$log"
      return 1
    fi
    if (( attempt > max_restarts )); then
      printf '\n[perl5] XS Makefiles still regenerating after %d restarts; stopping to avoid a loop.\n' "$max_restarts" >&2
      show_make_failure "$log"
      return 1
    fi

    # Leave the attempt log for later diagnosis, but keep the current failure
    # in target-make.log so the existing diagnose command still works.
    mv -f -- "$log" "$work/target-make.regenerated-$attempt.log"
    info "XS Makefiles regenerated (normal MakeMaker restart $attempt/$max_restarts); resuming incremental build"
    ((attempt+=1))
  done
}

# IMPORTANT: RUN_PERL and HOST_PERL must be executable PATHS, not command
# lines with -I flags. Perl's upstream Makefile uses HOST_PERL both to run
# code generators and as the symlink source in:
#     ln -s $(HOST_PERL) miniperl
# Appending -I to HOST_PERL makes ln parse it as an option (invalid option -I).
# Supply host-only library search paths through PERL5LIB instead. This is
# also respected by miniperl -f when generating POD and XS, without running
# any FuturaOS ELF executable on the WSL host.
host_perl="$source_host/miniperl"
host_perl5lib="$source_target/lib:$source_target"
# Preserve user's paths after the version-matched core tree (if set).
if [[ -n ${PERL5LIB:-} ]]; then host_perl5lib+=":$PERL5LIB"; fi

info 'Cross-compiling Perl 5.45.4 and selected core XS extensions'
run_target_make || exit 1
[[ -f "$source_target/perl" ]] || fail 'No target perl binary produced; refusing to mark build successful.'

if [[ ${1:-install} == install ]]; then
  info 'Staging Perl installation in FuturaOS base/usr (not the WSL host /usr)'
  ( cd "$source_target"
    PERL5LIB="$host_perl5lib" make install.perl DESTDIR="$root/base" LNS='ln -sfn' \
      HOST_PERL="$host_perl" RUN_PERL="$host_perl" >"$work/target-install.log" 2>&1 \
      || { tail -120 "$work/target-install.log"; exit 1; }
  )
  [[ -f "$root/base/usr/bin/perl" || -f "$root/base/usr/bin/perl5.45.4" ]] \
    || fail 'installperl did not install the Perl interpreter.'
  if [[ ! -e "$root/base/usr/bin/perl" && -f "$root/base/usr/bin/perl5.45.4" ]]; then
    ln -s perl5.45.4 "$root/base/usr/bin/perl"
  fi
  # Before declaring success, verify the real runtime paths and both halves
  # of the Fcntl XS extension. This catches a host-x86_64-linux @INC mismatch
  # (and an incomplete installperl pass) without ever executing target ELF on
  # the WSL build host.
  installed_arch="$root/base$expected_arch"
  installed_priv="$root/base/usr/lib/perl5/5.45.4"
  missing_install=()
  for installed_file in \
    "$installed_arch/Fcntl.pm" \
    "$installed_arch/auto/Fcntl/Fcntl.so" \
    "$installed_arch/Config.pm" \
    "$installed_priv/strict.pm"; do
    [[ -f $installed_file ]] || missing_install+=("$installed_file")
  done
  if (( ${#missing_install[@]} )); then
    printf '\n[perl5] Required Perl library files missing after install.perl:\n' >&2
    printf '  %s\n' "${missing_install[@]}" >&2
    printf '[perl5] Related files actually staged:\n' >&2
    find "$root/base/usr/lib/perl5" -type f \
      \( -name 'Fcntl.pm' -o -name 'Fcntl.so' -o -name 'Config.pm' -o -name 'strict.pm' \) \
      -print >&2 2>/dev/null || true
    fail 'Perl module installation is incomplete or installed into the wrong architecture directory'
  fi
  info 'Verified installed Fcntl XS, Config.pm and strict.pm in FuturaOS @INC paths'
  mkdir -p "$root/base/usr/share/futura/perl5-tests"
  cp "$here/tests/smoke.pl" "$root/base/usr/share/futura/perl5-tests/smoke.pl"
  cp "$here/tests/grp-smoke.pl" "$root/base/usr/share/futura/perl5-tests/grp-smoke.pl"
  cp "$here/tests/socket-posix-smoke.pl" "$root/base/usr/share/futura/perl5-tests/socket-posix-smoke.pl"
  info 'Installed. After boot: /usr/bin/perl /usr/share/futura/perl5-tests/smoke.pl'
fi
info 'Done. Build logs: third_party/perl/.work/*.log (or PERL5_WORKDIR).'
