#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
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

TEST_DIR="$SRC/build-tests"
CLI="$TEST_DIR/Source/astcenc-none"
UNIT="$TEST_DIR/test-unit"
DATA="$SRC/Test/Data"
IMG="$SRC/Test/Images/Small"
for f in "$CLI" "$UNIT" "$DATA/LDR-A-1x1.astc" "$IMG/LDR-RGB/ldr-rgb-00.png"; do
  [ -e "$f" ] || { echo "missing $f (mayhem/build.sh should have produced it)" >&2; emit_ctrf "astcenc" 0 1 0; exit 1; }
done

passed=0; failed=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1) Upstream GoogleTest unit suite: take the counts from gtest's own summary. A neutered or missing
#    binary prints no summary, which counts as a failure.
unit_out="$("$UNIT" 2>&1)"; unit_rc=$?
unit_pass="$(printf '%s\n' "$unit_out" | sed -n 's/^\[  PASSED  \] \([0-9][0-9]*\) tests\?\.$/\1/p')"
unit_fail="$(printf '%s\n' "$unit_out" | sed -n 's/^\[  FAILED  \] \([0-9][0-9]*\) tests\?, listed below:$/\1/p')"
if [ -n "$unit_pass" ] && [ "$unit_pass" -gt 100 ]; then passed=$((passed + unit_pass)); else failed=$((failed + 1)); echo "FAIL unit: no gtest summary / too few tests" >&2; fi
if [ -n "$unit_fail" ]; then failed=$((failed + unit_fail)); fi
[ "$unit_rc" -eq 0 ] || { [ -n "$unit_fail" ] || failed=$((failed + 1)); }

# 2) Known-answer probes through the real CLI (dynamically linked): fixed input -> asserted output.
check() {   # check <name> <expected> <actual>
  if [ "$2" = "$3" ] && [ -n "$3" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}
cd "$WORK"
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# LDR compress of a 1x1 PNG must reproduce upstream's reference ASTC file byte-for-byte.
"$CLI" -cl "$DATA/LDR-A-1x1.png" ldr.astc 6x6 -fast >/dev/null 2>&1
check "ldr-1x1-compress" "$(sha "$DATA/LDR-A-1x1.astc")" "$(sha ldr.astc)"
# HDR compress of a 1x1 EXR must reproduce the reference as well.
"$CLI" -ch "$DATA/HDR-A-1x1.exr" hdr.astc 6x6 -fast >/dev/null 2>&1
check "hdr-1x1-compress" "$(sha "$DATA/HDR-A-1x1.astc")" "$(sha hdr.astc)"
# Decoding the reference ASTC block yields exactly this TGA (pixel B=00 G=ad R=2b A=ff).
"$CLI" -dl "$DATA/LDR-A-1x1.astc" ldr.tga >/dev/null 2>&1
check "ldr-1x1-decode" "088ebaee1a9f402e5653d9b8c51c12675e3e741b4b5a8f66e24952942192c207" "$(sha ldr.tga)"
"$CLI" -dh "$DATA/HDR-A-1x1.astc" hdr.hdr >/dev/null 2>&1
check "hdr-1x1-decode" "0ecf2b25156010b267e0a5ecb284e1d4cf0812aff4264fe2f7fa155cd79cf98f" "$(sha hdr.hdr)"
# A real photo at 6x6/-medium: compressed bitstream, decoded image and PSNR are all deterministic.
"$CLI" -cl "$IMG/LDR-RGB/ldr-rgb-00.png" photo.astc 6x6 -medium >/dev/null 2>&1
check "photo-compress" "743f4853aad69eeddb3133f9f5ec7148f7563d53ace3a32fbbca5106a4551746" "$(sha photo.astc)"
"$CLI" -dl photo.astc photo.tga >/dev/null 2>&1
check "photo-decode" "bb2929e443072ef28e86e3949a8faf3bd63aaf0638418d6bacf3ce75df8ff530" "$(sha photo.tga)"
psnr="$("$CLI" -tl "$IMG/LDR-RGB/ldr-rgb-00.png" rt.tga 6x6 -medium 2>/dev/null | sed -n 's/^ *PSNR (LDR-RGB): *\([0-9.]*\) dB$/\1/p')"
check "photo-psnr" "32.4055" "$psnr"
check "photo-roundtrip" "ea33dbc88d42757a5fd38ef11e990e9e8ea32c96b8200710fec8893dd60d34c9" "$(sha rt.tga)"

emit_ctrf "astcenc-gtest+cli-kat" "$passed" "$failed" 0
