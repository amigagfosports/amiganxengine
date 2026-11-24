#!/bin/sh
# NXEngine-evo (Cave Story) for AmigaOS 3.x / AmiCradle (68040 + FPU, libnix,
# SDL 2 through GFOpenGPU), built with the os32-gcc16 stove: OpenAmigaGCC
# 16.2.0-open3 or open4, known by their archives' SHA-256, or GFOpenAmigaGCC
# 16.2.0-open5 (Cradle's os32-gcc16 stove since the evening of 2 November
# 2026), which has no published archive: STOVE.json's release and the
# compiler's own --version name it, and the receipt records the SHA-256 of the
# compiler's own programs instead. This is the build Cradle's stove_build runs
# (STOVE= and OUT= set, target .).
#   STOVE      the stove (default ~/AmiCradle/stoves/os32-gcc16, then
#              ~/AmigaChrome/stoves/os32-gcc16)
#   OUT        the output directory (default build-amiga)
#   NX_SOURCE  a local upstream checkout holding the pinned commit; without
#              it the pinned commit (gameports/catalog.json) is fetched
#   JOBS       parallel compiles (default: the host's processors, at most 8)
# patches/ is applied to a copy of upstream (git archive of the pinned
# commit), with no fuzz, then patch_amigaos3_deps.py; the sources are
# upstream's own CMake lists (the same globs), compiled with the stove's
# compilers and linked with the stove's SDL 2, SDL2_mixer, SDL2_image, libpng
# and zlib. Outputs: NXEngine/nxengine-evo, NXEngine/LICENSE, receipt.json,
# build.log. The Cave Story data is not built here: runtime-data/build-amiga.sh
# stages it for a lab, and it is never committed.
# MIT, Copyright (c) 2026 AmiCradle Team.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${STOVE:-}" ]; then
    STOVE="$HOME/AmiCradle/stoves/os32-gcc16"
    [ -d "$STOVE" ] || STOVE="$HOME/AmigaChrome/stoves/os32-gcc16"
fi
OUT=${OUT:-"$HERE/build-amiga"}
if [ -z "${JOBS:-}" ]; then
    JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
    [ "$JOBS" -le 8 ] || JOBS=8
fi
P="$STOVE/prefix"
SDK="$P/m68k-amigaos"
CC="$P/bin/m68k-amigaos-gcc"
CXX="$P/bin/m68k-amigaos-g++"

# the compiler is recorded, not checked (BL-144): scripts/record_stove.py
# prints "RELEASE ARCHIVE-SHA256" (the release the compiler's --version names;
# "unpublished" when the stove names no archive) and the compiler's own
# --version line on stderr; it fails only when the stove has no compiler
COMPILER=$(python3 "$HERE/scripts/record_stove.py" --stove "$STOVE")
RELEASE=${COMPILER% *}
ARCHIVE=${COMPILER#* }
"$CC" --version | head -n 1

# SDL 2 and its satellites (GFOpenGPU's link stubs) from the stove's SDK;
# libpng and zlib: the locked codec inventory staged inside the stove
# (toolchain/port-dependencies.lock.json, scripts/port_dependencies.py), or
# the stove SDK's own if it has them. Either way they come from the stove.
missing=0
for f in include/SDL2/SDL.h include/SDL2/SDL_mixer.h include/SDL2/SDL_image.h \
         lib/libSDL2.a lib/libSDL2_mixer.a lib/libSDL2_image.a lib/libGL.a; do
    [ -f "$SDK/$f" ] || { echo "the stove has no $f"; missing=1; }
done
[ "$missing" -eq 0 ] || exit 2
if DEPS=$(python3 "$HERE/scripts/port_dependencies.py" verify --stove "$STOVE" --require zlib png 2>/dev/null); then
    CODECS="locked port-deps inside the stove (toolchain/port-dependencies.lock.json)"
elif [ -f "$SDK/lib/libpng.a" ] && [ -f "$SDK/lib/libz.a" ] && [ -f "$SDK/include/png.h" ] && [ -f "$SDK/include/zlib.h" ]; then
    DEPS=$SDK
    CODECS="the stove SDK's own"
else
    echo "no libpng/zlib in $STOVE (neither staged port-deps nor the SDK's own)"
    python3 "$HERE/scripts/port_dependencies.py" verify --stove "$STOVE" --require zlib png || true
    exit 2
fi
echo "codecs: $CODECS ($DEPS)"

eval "$(python3 - "$HERE/gameports/catalog.json" <<'EOF'
import json, shlex, sys
src = json.load(open(sys.argv[1]))["ports"]["nxengine-evo"]["source"]
print(f"PIN={shlex.quote(src['commit'])}")
print(f"URL={shlex.quote(src['url'])}")
EOF
)"
REPO_REV=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nxengine-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

if [ -n "${NX_SOURCE:-}" ]; then
    UP=$NX_SOURCE
else
    UP="$WORK/upstream"
    git init -q "$UP"
    git -C "$UP" fetch -q --depth 1 "$URL" "$PIN"
fi
git -C "$UP" cat-file -e "$PIN^{commit}"
EPOCH=$(git -C "$UP" show -s --format=%ct "$PIN")

SRC="$WORK/src"
mkdir -p "$SRC" "$OUT"
git -C "$UP" archive "$PIN" | tar -xf - -C "$SRC"
for patch in "$HERE"/patches/*.patch; do
    [ -f "$patch" ] || continue
    echo "patch: $(basename "$patch")"
    patch --batch --forward --fuzz=0 -p1 -d "$SRC" < "$patch"
done
python3 "$HERE/patch_amigaos3_deps.py" "$SRC"

# upstream's source list (CMakeLists.txt: the same globs, ai/ recursive)
SOURCES=$(cd "$SRC" && {
    for d in src src/TextBox src/autogen src/common src/Utils src/endgame \
             src/graphics src/intro src/pause src/siflib src/sound src/i18n; do
        find "$d" -maxdepth 1 -type f -name '[a-zA-Z]*.cpp'
    done
    find src/ai -type f -name '[a-zA-Z]*.cpp'
} | LC_ALL=C sort)
[ "$(printf '%s\n' $SOURCES | wc -l)" -gt 100 ] || { echo "could not read the source list"; exit 2; }

# spdlog as a compiled library (amiga/spdlog_lib.cpp, as spdlog's own
# SPDLOG_COMPILED_LIB build): header-only, every source compiled the logger
# and fmt again, ten times the work, and the build did not finish inside
# stove_build's 900 s
cp "$HERE/amiga/spdlog_lib.cpp" "$SRC/src/amiga_spdlog_lib.cpp"
SOURCES="$SOURCES src/amiga_spdlog_lib.cpp"

# upstream's own flags for the pc platform (-std=c++11, -Wall), Release
# (-O2 -DNDEBUG); -fno-delete-null-pointer-checks: address 0 is memory on an
# Amiga
FLAGS="-noixemul -m68040 -m68881 -pthread -fno-delete-null-pointer-checks
 -std=c++11 -O2 -DNDEBUG -DSPDLOG_COMPILED_LIB -Wall -Wno-attributes
 -ffile-prefix-map=$SRC=. -I$SRC -I$SRC/deps -I$SDK/include/SDL2 -I$DEPS/include"
LIBS="-lSDL2_mixer -lSDL2_image -lSDL2 -lpng -lz -lGL -lm -latomic -pthread"

mkdir -p "$SRC/obj"
if ! (
    cd "$SRC"
    export SOURCE_DATE_EPOCH="$EPOCH"
    printf '%s\n' $SOURCES | xargs -P "$JOBS" -I{} sh -c '
        o=obj/$(echo "{}" | tr / _).o
        echo "c++ {}"
        "$0" $1 -c "{}" -o "$o"' "$CXX" "$FLAGS" &&
    OBJS=$(for s in $SOURCES; do printf '%s ' "obj/$(echo "$s" | tr / _).o"; done) &&
    echo "link nxengine-evo" &&
    # shellcheck disable=SC2086
    "$CXX" -noixemul -m68040 -m68881 -pthread -o nxengine-evo $OBJS -L"$SDK/lib" -L"$DEPS/lib" $LIBS
) > "$OUT/build.log" 2>&1; then
    tail -n 120 "$OUT/build.log"
    exit 1
fi
echo "compiled $(printf '%s\n' $SOURCES | wc -l) sources (upstream's and amiga/spdlog_lib.cpp); warnings, each once (from $(grep -c 'warning:' "$OUT/build.log" || true) in all):"
grep 'warning:' "$OUT/build.log" | sed -e 's/^\.\///' | sort | uniq -c | sort -rn | head -n 40 || true

EXE="$SRC/nxengine-evo"
[ -f "$EXE" ] || { echo "no executable: see build.log"; tail -n 60 "$OUT/build.log"; exit 2; }
[ "$(od -An -tx1 -N4 "$EXE" | tr -d ' \n')" = "000003f3" ] || { echo "not an Amiga HUNK executable"; exit 2; }

# the drawer: the program and the licence (runtime-data/build-amiga.sh
# stages the data that goes beside it)
D="$OUT/NXEngine"
mkdir -p "$D"
cp "$EXE" "$D/nxengine-evo"
cp "$SRC/LICENSE" "$D/LICENSE"

python3 - "$HERE" "$OUT" "$PIN" "$REPO_REV" "$EPOCH" "$STOVE" "$RELEASE" "$ARCHIVE" "$DEPS" "$CODECS" <<'EOF'
import hashlib, json, sys
from pathlib import Path
here, out, pin, rev, epoch, stove, release, archive, deps, codecs = Path(sys.argv[1]), Path(sys.argv[2]), *sys.argv[3:]
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
sdk = Path(stove) / "prefix/m68k-amigaos"
inputs = ["lib/libSDL2.a", "lib/libSDL2_mixer.a", "lib/libSDL2_image.a", "lib/libGL.a",
          "include/SDL2/SDL.h", "include/SDL2/SDL_mixer.h", "include/SDL2/SDL_image.h"]
codec_inputs = ["lib/libpng.a", "lib/libz.a", "include/png.h", "include/zlib.h"]
drawer = out / "NXEngine"
receipt = {
    "upstream_commit": pin, "repository_commit": rev, "source_date_epoch": epoch,
    "recipe": {n: sha(here / n) for n in ("build-amiga.sh", "patch_amigaos3_deps.py", "amiga/spdlog_lib.cpp")},
    "patches": {p.name: sha(p) for p in sorted((here / "patches").glob("*.patch"))},
    "compiler_release": release, "compiler_archive_sha256": archive,
    "sdk_inputs": {n: sha(sdk / n) for n in inputs if (sdk / n).is_file()},
    "codecs": codecs,
    "codec_inputs": {n: sha(Path(deps) / n) for n in codec_inputs if (Path(deps) / n).is_file()},
    "network": False,
    "executable_sha256": sha(drawer / "nxengine-evo"),
    "executable_bytes": (drawer / "nxengine-evo").stat().st_size,
    "scope": "Source build only; no network code; no game data; no runtime or release pass implied",
}
if archive == "unpublished":
    # no archive to name: the compiler's own programs, by SHA-256
    prefix = Path(stove) / "prefix"
    files = ["bin/m68k-amigaos-gcc", "bin/m68k-amigaos-g++", "bin/m68k-amigaos-as", "bin/m68k-amigaos-ld"]
    files += sorted(str(p.relative_to(prefix)) for p in prefix.glob("libexec/gcc/m68k-amigaos/*/cc1*"))
    receipt["compiler_files_sha256"] = {f: sha(prefix / f) for f in files if (prefix / f).is_file()}
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
EOF
