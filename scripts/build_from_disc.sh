#!/usr/bin/env bash
# One-shot Linux/macOS build: your legal disc -> recompiled C -> native exe.
#
# Usage (from anywhere):
#   scripts/build_from_disc.sh "/path/to/Monsters, Inc. - Scare Island (Europe).cue" \
#       [--bios /path/to/SCPH1001.BIN] [--build-dir build-release] [--jobs N] \
#       [--debug] [-- <extra cmake -D args>]
#
# Steps:
#   1. check tools, fetch the psxrecomp submodule if it is missing
#   2. build the recompiler emitters (psxrecomp-game / psxrecomp-bios)
#   3. probe the disc -> game.toml, seeds/ghidra_funcs.txt, catalog_identity.json
#   4. keep CMakeLists.txt GEN_MARKER + codegen_setup.c in step with the disc's
#      boot EXE (other PAL language discs use a different serial)
#   5. Generate (OpenBIOS backend + game C), then cmake/ninja the runtime
#
# The disc is probed in place and never copied into the repo; only the boot
# EXE is extracted to disc/ (gitignored). Re-running is safe.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CUE=""
BIOS=""
BUILD_DIR="build-release"
BUILD_TYPE="Release"
JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
EXTRA_CMAKE=()
DEFAULT_BOOT="SCES_037.59"

die() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bios) BIOS="${2:?--bios needs a path}"; shift 2 ;;
    --build-dir) BUILD_DIR="${2:?}"; shift 2 ;;
    --jobs|-j) JOBS="${2:?}"; shift 2 ;;
    --debug) BUILD_TYPE="RelWithDebInfo"; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; EXTRA_CMAKE=("$@"); break ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$CUE" ]] || die "only one .cue please"; CUE="$1"; shift ;;
  esac
done

[[ -n "$CUE" ]] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ -f "$CUE" ]] || die "disc not found: $CUE"
[[ "${CUE,,}" == *.cue ]] || die "expected a .cue (Redump BIN/CUE dump), got: $CUE"
CUE="$(cd "$(dirname "$CUE")" && pwd)/$(basename "$CUE")"
if [[ -n "$BIOS" ]]; then
  [[ -f "$BIOS" ]] || die "BIOS not found: $BIOS"
  BIOS="$(cd "$(dirname "$BIOS")" && pwd)/$(basename "$BIOS")"
fi

echo "== 1/5 Checking tools =="
missing=()
for t in git python3 cmake ninja; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 \
   && ! command -v clang >/dev/null 2>&1; then missing+=("gcc"); fi
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "missing: ${missing[*]}" >&2
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      echo "On Windows, run this from the 'MSYS2 MINGW64' shell after:" >&2
      echo "  pacman -S --needed git mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake \\" >&2
      echo "    mingw-w64-x86_64-ninja mingw-w64-x86_64-python mingw-w64-x86_64-ccache" >&2
      exit 1 ;;
  esac
  echo "On Ubuntu/Debian:" >&2
  echo "  sudo apt install build-essential git python3 cmake ninja-build pkg-config \\" >&2
  echo "    libgl1-mesa-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev \\" >&2
  echo "    libxss-dev libxtst-dev libxkbcommon-dev libwayland-dev wayland-protocols \\" >&2
  echo "    libegl1-mesa-dev libasound2-dev libpulse-dev libudev-dev libdbus-1-dev" >&2
  exit 1
fi
cmake_ver="$(cmake --version | head -1 | awk '{print $3}')"
if [[ "$(printf '%s\n3.20\n' "$cmake_ver" | sort -V | head -1)" != "3.20" ]]; then
  die "cmake >= 3.20 required (found $cmake_ver)"
fi

PSXRECOMP_URL="https://github.com/mstan/psxrecomp.git"
PSXRECOMP_PIN="155e269ba5d50fe36523846f908cf124dc1561a0"  # matches the gitlink / framework_pins.txt
if [[ ! -f psxrecomp/runtime/runtime.cmake ]]; then
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "  fetching psxrecomp submodule…"
    git submodule update --init --recursive || die "submodule fetch failed"
  else
    # Unpacked from a ZIP: no .git, so no submodules. Clone the pinned framework.
    echo "  no git checkout (ZIP download?) — cloning psxrecomp @ ${PSXRECOMP_PIN:0:8}…"
    rmdir psxrecomp 2>/dev/null || true
    [[ -e psxrecomp ]] && die "psxrecomp/ exists but is incomplete; remove it and re-run"
    git clone "$PSXRECOMP_URL" psxrecomp
    git -C psxrecomp checkout -q "$PSXRECOMP_PIN"
    git -C psxrecomp submodule update --init --recursive
  fi
fi

# Framework fixes this title depends on (see patches/psxrecomp/README.md).
for pf in "$ROOT"/patches/psxrecomp/*.patch; do
  [[ -f "$pf" ]] || continue
  if git -C psxrecomp apply --reverse --check "$pf" >/dev/null 2>&1; then
    echo "  framework patch already applied: $(basename "$pf")"
  elif git -C psxrecomp apply "$pf"; then
    echo "  applied framework patch: $(basename "$pf")"
  else
    die "framework patch does not apply: $pf (psxrecomp moved past ${PSXRECOMP_PIN:0:8}?)"
  fi
done

echo "== 2/5 Building recompiler emitters =="
if [[ -x build-recompiler/psxrecomp-game && -x build-recompiler/psxrecomp-bios ]]; then
  echo "  already built (delete build-recompiler/ to force)"
else
  bash psxrecomp/tools/ci/build_emitters.sh --jobs "$JOBS"
fi

echo "== 3/5 Probing disc =="
[[ -f game.toml ]] && cp -f game.toml game.toml.bak
mkdir -p disc seeds
python3 psxrecomp/tools/new_project_layout/probe_disc.py "$CUE" \
  --write-game-toml game.toml \
  --write-catalog catalog_identity.json \
  --write-seeds seeds/ghidra_funcs.txt \
  --json-out disc_probe.json \
  --disc-rel "$CUE" \
  --out-dir disc \
  --write-boot-exe disc \
  --players 1 \
  --display-name "Monsters, Inc. Scare Island" >/dev/null

BOOT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["boot_exe"])' disc_probe.json)"
SERIAL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serial"])' disc_probe.json)"
ENTRY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["entry_pc"])' disc_probe.json)"
echo "  disc: $SERIAL  boot EXE: $BOOT  entry: $ENTRY"
case "$SERIAL" in
  SCES-03759) ;;
  SCES-0376[0-9]) echo "  note: $SERIAL is another PAL language release of Scare Island — supported, names rewired below." ;;
  SCUS-94635) echo "  note: $SERIAL is the US release (Monsters, Inc. Scream Team) — tested: boots, FMV, menus, tutorial gameplay." ;;
  *) echo "  WARNING: $SERIAL is not a known Monsters, Inc. Scare Island serial. Continuing anyway." >&2 ;;
esac

python3 - "$SERIAL" <<'MERGE'
import re, sys, pathlib
serial = sys.argv[1]
g = pathlib.Path("game.toml"); t = g.read_text(encoding="utf-8")
enh = pathlib.Path("game.enhancements.toml").read_text(encoding="utf-8")
for sec in re.findall(r"(?m)^\[([a-z_.]+)\]", enh):
    t = re.sub(r"(?ms)^\[" + re.escape(sec) + r"\]\n.*?(?=^\[|\Z)", "", t)
if serial == "SCUS-94635":
    t = t.replace('name = "Monsters, Inc. Scare Island"', 'name = "Monsters, Inc. Scream Team"')
    t = t.replace('"Monsters, Inc. Scare Island Recompiled"', '"Monsters, Inc. Scream Team Recompiled"')
t = t.rstrip() + "\n\n" + enh[enh.index("[video]"):]
g.write_text(t, encoding="utf-8")
print("  merged game.enhancements.toml into game.toml")
MERGE

echo "== 4/5 Wiring boot EXE name =="
CUR="$(sed -n 's#.*GEN_MARKER "generated/\(.*\)_dispatch\.c".*#\1#p' CMakeLists.txt | head -1)"
if [[ "$CUR" != "$BOOT" ]]; then
  python3 - "$CUR" "$BOOT" <<'PY'
import sys, pathlib
old, new = sys.argv[1], sys.argv[2]
for f in ("CMakeLists.txt", "codegen_setup.c"):
    p = pathlib.Path(f)
    t = p.read_text(encoding="utf-8")
    t = t.replace(f"generated/{old}_dispatch.c", f"generated/{new}_dispatch.c")
    t = t.replace(f"generated/{old}_full_*.c", f"generated/{new}_full_*.c")
    p.write_text(t, encoding="utf-8")
print(f"  GEN_MARKER {old} -> {new}")
PY
  rm -f "$BUILD_DIR/CMakeCache.txt"
else
  echo "  GEN_MARKER already $BOOT"
fi
# Point the BootEntry symbol at the real entry PC from the EXE header.
python3 - "$ENTRY" <<'PY'
import re, sys, pathlib
entry = sys.argv[1]
p = pathlib.Path("symbols.toml")
t = p.read_text(encoding="utf-8")
t2 = re.sub(r'(\[\[func\]\]\s*\npc\s*=\s*)0x[0-9A-Fa-f]+(\s*\nname\s*=\s*"BootEntry")',
            lambda m: m.group(1) + entry + m.group(2), t, count=1)
if t2 != t:
    p.write_text(t2, encoding="utf-8")
PY
python3 tools/sync_symbols.py >/dev/null 2>&1 \
  || echo "  (skipped psx_symbols.h refresh: needs Python 3.11+ or 'pip install tomli')"

echo "== 5/5 Generate + build =="
GEN_ARGS=(--config game.toml --project-root . --disc "$CUE")
[[ -n "$BIOS" ]] && GEN_ARGS+=(--bios "$BIOS")
python3 psxrecomp/psxrecomp_cli.py generate "${GEN_ARGS[@]}"

cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DPSXRECOMP_REQUIRE_GAME_C=ON "${EXTRA_CMAKE[@]}"
cmake --build "$BUILD_DIR" --target psx-runtime -j "$JOBS"

STATE="$BUILD_DIR/mods/state.toml"
if [[ ! -f "$STATE" ]]; then
  cp "$ROOT/mods/state.default.toml" "$STATE"
  echo "  wrote default mod selection: $STATE (PGXP + Fast Loading on, Widescreen off)"
fi

EXE_NAME="$(cat "$BUILD_DIR/psxrecomp_exe_name-psx-runtime.txt" 2>/dev/null || echo Scareisland_Recompiled)"
echo
echo "Done. Run it with:"
echo "  \"$ROOT/$BUILD_DIR/$EXE_NAME\""
echo "Toggle Widescreen / PGXP / Fast Loading in: $STATE"
