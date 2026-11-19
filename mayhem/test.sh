#!/usr/bin/env bash
#
# mayhem/test.sh — RUN fastp's own unit tests and known-answer CLI checks (built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/mayhem/build/fastp-test"     # upstream Makefile build with its normal flags (build.sh step 1)
if [ ! -x "$BIN" ]; then
  echo "FATAL: $BIN missing — mayhem/build.sh did not build the test binary" >&2
  emit_ctrf "fastp-unittest+kat" 0 1 0
  exit 1
fi
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
passed=0; failed=0
ok()  { echo "PASS: $1"; passed=$((passed+1)); }
bad() { echo "FAIL: $1"; failed=$((failed+1)); }

# 1) Upstream's built-in unit tests (`fastp test`, src/unittest.cpp). FastqReader::test reads
#    testdata/R1.fq relative to the cwd, so run from the repo root. Each test prints "<name>: PASSED".
( cd "$SRC" && "$BIN" test ) > "$W/unit.txt" 2>&1
for t in fastp_simd::testSimd Sequence::test Read::test FastqReader::test OverlapAnalysis::test \
         Filter::test AdapterTrimmer::test BaseCorrector::test PolyX::test NucleotideTree::test Evaluator::test; do
  if grep -qxF "$t: PASSED" "$W/unit.txt"; then ok "$t"; else bad "$t"; fi
done

# 2) Known-answer checks of the CLI on upstream's testdata (values from fastp v1.4.0 at -w 1, which
#    makes the output order deterministic).
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$1" "$2" 2>/dev/null; }
md5() { md5sum < "$1" | cut -d' ' -f1; }
R1="$SRC/testdata/R1.fq"; R2="$SRC/testdata/R2.fq"

# single-end: 9 reads in, 1 too short, 8 out, exact trimmed output
"$BIN" -i "$R1" -o "$W/se.fq" -w 1 -j "$W/se.json" -h "$W/se.html" >/dev/null 2>&1
got=$(jget "$W/se.json" '(d["summary"]["before_filtering"]["total_reads"], d["summary"]["before_filtering"]["total_bases"], d["summary"]["after_filtering"]["total_reads"], d["filtering_result"]["too_short_reads"])')
[ "$got" = "(9, 1208, 8, 1)" ] && ok "se-json-counts" || bad "se-json-counts (got '$got')"
[ "$(md5 "$W/se.fq" 2>/dev/null)" = "2e4bc16cedcd1fb158f6d1020861362c" ] && ok "se-output" || bad "se-output"

# paired-end merge: 18 reads in, 8 merged reads with exact content
"$BIN" -i "$R1" -I "$R2" -o "$W/o1.fq" -O "$W/o2.fq" -m --merged_out "$W/m.fq" -w 1 -j "$W/pe.json" -h "$W/pe.html" >/dev/null 2>&1
got=$(jget "$W/pe.json" '(d["summary"]["before_filtering"]["total_reads"], d["summary"]["after_filtering"]["total_reads"], d["summary"]["after_filtering"]["total_bases"])')
[ "$got" = "(18, 8, 1552)" ] && ok "pe-merge-json" || bad "pe-merge-json (got '$got')"
[ "$(md5 "$W/m.fq" 2>/dev/null)" = "20d9308895491df7523f5f5a06c7086d" ] && ok "pe-merged-output" || bad "pe-merged-output"

# gzip in and out (isa-l inflate + libdeflate compress): same reads as the plain single-end run
gzip -n -c "$R1" > "$W/in.fq.gz"
"$BIN" -i "$W/in.fq.gz" -o "$W/gz.fq.gz" -w 1 -j "$W/gz.json" -h "$W/gz.html" >/dev/null 2>&1
[ "$(gzip -dc "$W/gz.fq.gz" 2>/dev/null | md5sum | cut -d' ' -f1)" = "2e4bc16cedcd1fb158f6d1020861362c" ] && ok "gz-roundtrip" || bad "gz-roundtrip"

# adapter FASTA: GGAAGG trims 5 reads; output identical to --adapter_sequence=GGAAGG
printf '>x\nAGATCGGAAGAGC\n>y\nGGAAGG\n' > "$W/ad.fa"
"$BIN" -i "$R1" -o "$W/ad.fq" --adapter_fasta "$W/ad.fa" -w 1 -j "$W/ad.json" -h "$W/ad.html" >/dev/null 2>&1
[ "$(md5 "$W/ad.fq" 2>/dev/null)" = "d4cf5dc43a129c474a839c647cd5284e" ] && ok "adapter-fasta-output" || bad "adapter-fasta-output"

# 3) Upstream's offline regression script for issue #697 (scripts/test_issue_697_stdout_merge.sh):
#    --stdin --interleaved_in --merge --stdout must emit exactly one merged read (4 FASTQ lines). The
#    script runs ./fastp and calls `python`, so run it from a scratch dir holding a ./fastp symlink to
#    the test binary (its fastp.json/fastp.html land there, not in $SRC) and a `python` shim.
mkdir -p "$W/i697/bin" && ln -sf "$BIN" "$W/i697/fastp"
command -v python >/dev/null 2>&1 || ln -sf "$(command -v python3)" "$W/i697/bin/python"
if ( cd "$W/i697" && PATH="$W/i697/bin:$PATH" bash "$SRC/scripts/test_issue_697_stdout_merge.sh" ) >"$W/i697.log" 2>&1; then
  ok "issue-697-stdout-merge"; else bad "issue-697-stdout-merge"; cat "$W/i697.log"; fi

emit_ctrf "fastp-unittest+kat" "$passed" "$failed" 0
