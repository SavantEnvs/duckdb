#!/usr/bin/env bash
#
# mayhem/build.sh — build DuckDB's fuzz harnesses (sanitized) and the CLI shell used by mayhem/test.sh
# (normal flags). Runs inside the commit image as `mayhem` in /mayhem; re-runnable and offline.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Line tables only (DWARF 3): full -g makes each sanitized DuckDB harness ~840 MB and the image ~10 GB.
: "${DEBUG_FLAGS:=-gline-tables-only -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE COVERAGE_FLAGS

# A sanitized DuckDB translation unit (unity build) peaks at a few GB, so cap the default
# parallelism by available memory (cgroup limit if any) as well as by cores.
if [ -z "${MAYHEM_JOBS:-}" ]; then
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  if [ -r /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != max ]; then
    cg_kb=$(( $(cat /sys/fs/cgroup/memory.max) / 1024 )); [ "$cg_kb" -lt "$mem_kb" ] && mem_kb=$cg_kb
  fi
  MAYHEM_JOBS=$(( mem_kb / 3000000 )); [ "$MAYHEM_JOBS" -ge 1 ] || MAYHEM_JOBS=1
  [ "$MAYHEM_JOBS" -le "$(nproc)" ] || MAYHEM_JOBS=$(nproc)
fi
export MAYHEM_JOBS

cd "$SRC"

# Options shared by both builds: only the static library (+ its static extensions: core_functions,
# parquet, json, icu), no unit-test runner, and DuckDB's own ASan/UBSan switches off — the
# sanitizers come from $SANITIZER_FLAGS instead.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
        -DBUILD_UNITTESTS=OFF -DBUILD_BENCHMARKS=OFF -DENABLE_SANITIZER=OFF -DENABLE_UBSAN=OFF)

# 1) Sanitized library (the fuzzed code), DWARF 3.
FUZZ_DIR="$SRC/build/fuzz"
cmake -S "$SRC" -B "$FUZZ_DIR" "${COMMON[@]}" -DBUILD_SHELL=OFF \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target duckdb_static

# 2) Each harness twice: libFuzzer binary + run-once standalone reproducer. Leak detection is turned
#    off at build time by mayhem/lsan_off.cc. The harnesses are upstream's own (test/ossfuzz/).
mapfile -t LIBS < <(find "$FUZZ_DIR/src" "$FUZZ_DIR/extension" "$FUZZ_DIR/third_party" -name '*.a' | sort)
[ "${#LIBS[@]}" -gt 0 ]
HARNESS_FLAGS=($SANITIZER_FLAGS $DEBUG_FLAGS -I"$SRC/src/include")
LINK_LIBS=(-Wl,--start-group "${LIBS[@]}" -Wl,--end-group -lpthread -ldl -lm)

OBJ="$FUZZ_DIR/harness"; mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

for h in csv_json_fuzz_test parquet_fuzz_test parse_fuzz_test; do
  $CXX "${HARNESS_FLAGS[@]}" -c "$SRC/test/ossfuzz/$h.cpp" -o "$OBJ/$h.o"
  $CXX "${HARNESS_FLAGS[@]}" $LIB_FUZZING_ENGINE "$OBJ/$h.o" "$OBJ/lsan_off.o" "${LINK_LIBS[@]}" -o "$SRC/$h"
  $CXX "${HARNESS_FLAGS[@]}" "$OBJ/$h.o" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" "${LINK_LIBS[@]}" -o "$SRC/$h-standalone"
done

# 3) The test oracle: the DuckDB CLI shell built with the project's NORMAL flags (no sanitizer, no
#    DWARF override), so mayhem/test.sh only RUNS it.
TEST_DIR="$SRC/build/test"
cmake -S "$SRC" -B "$TEST_DIR" "${COMMON[@]}" -DBUILD_SHELL=ON \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS" --target shell
[ -x "$TEST_DIR/duckdb" ]
