#!/usr/bin/env bash
#
# mayhem/build.sh — build fastp's fuzz targets and its functional-test binary.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC/mayhem/build"          # gitignored (mayhem/.gitignore); everything build.sh makes lands here
mkdir -p "$OUT"

# Dependencies come from apt (mayhem/Dockerfile) as shared libraries in the system lib dir; upstream's
# Makefile then links them dynamically (it only goes -static when it finds lib*.a in /usr/local/lib).
LIBS="-lisal -ldeflate -lhwy -lpthread"

# 1) The functional-test binary (mayhem/test.sh runs it): upstream's own Makefile with its NORMAL flags
#    (-O3 -g), objects in a separate dir so the sanitized build below never mixes with it.
env -u CXXFLAGS -u LD_FLAGS CXXFLAGS="$COVERAGE_FLAGS" LD_FLAGS="$COVERAGE_FLAGS" \
  make -j"$MAYHEM_JOBS" DIR_OBJ="$OUT/obj-test" TARGET="$OUT/fastp-test"

# 2) The fuzzed project: the same Makefile, every source compiled with the sanitizers, SanCov
#    (-fsanitize=fuzzer-no-link, unconditional so the no-sanitizer build is still coverage-guided) and
#    DWARF 3. Upstream's Makefile appends the environment's CXXFLAGS/LD_FLAGS to its own, so its -O3 -g
#    stay and our -gdwarf-3 (later on the line) wins. The LSan-off hook is linked into every binary.
FUZZ_CXXFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
# mayhem/new_delete_malloc.cc (see its header) forwards global new/delete to malloc/free so upstream's
# new[]/delete mismatch, hit on every run, does not abort every input; ASan still checks every access.
$CXX $FUZZ_CXXFLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"
$CXX $FUZZ_CXXFLAGS -c "$SRC/mayhem/new_delete_malloc.cc" -o "$OUT/new_delete_malloc.o"
EXTRA_OBJS="$OUT/lsan_off.o $OUT/new_delete_malloc.o"
CXXFLAGS="$FUZZ_CXXFLAGS" LD_FLAGS="$FUZZ_CXXFLAGS $EXTRA_OBJS" \
  make -j"$MAYHEM_JOBS" DIR_OBJ="$OUT/obj-fuzz" TARGET="$OUT/fastp"

# 3) Wrapper targets (gz / two-file PE / adapter FASTA): upstream's main.cpp renamed to fastp_main,
#    plus mayhem/fastp_fuzz_main.cpp in one of three staging modes. All other objects are shared.
INC="-std=c++11 -pthread -I$SRC/src"
$CXX $FUZZ_CXXFLAGS -O3 $INC -Dmain=fastp_main -c "$SRC/src/main.cpp" -o "$OUT/main_renamed.o"
LIB_OBJS=$(ls "$OUT"/obj-fuzz/*.o | grep -v '/main\.o$')
for mode in gz pe adapter_fasta; do
  def=$(echo "${mode%%_*}" | tr a-z A-Z)
  $CXX $FUZZ_CXXFLAGS $INC -DFASTP_FUZZ_MODE_$def -c "$SRC/mayhem/fastp_fuzz_main.cpp" -o "$OUT/fastp_fuzz_main_$mode.o"
  $CXX $FUZZ_CXXFLAGS "$OUT/fastp_fuzz_main_$mode.o" "$OUT/main_renamed.o" $LIB_OBJS $EXTRA_OBJS \
    $LIBS -o "$OUT/fastp_$mode"
done

ls -l "$OUT/fastp" "$OUT/fastp_gz" "$OUT/fastp_pe" "$OUT/fastp_adapter_fasta" "$OUT/fastp-test"
