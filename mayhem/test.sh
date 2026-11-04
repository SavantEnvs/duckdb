#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer oracle for DuckDB: RUNS the normal-flags CLI shell that mayhem/build.sh
# produced (build/test/duckdb) over SQL statements and in-tree data files (data/parquet-testing, ...) and
# compares each result with its known value. A neutered or no-op program fails every case.
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

DUCKDB="${DUCKDB_BIN:-$SRC/build/test/duckdb}"
[ -x "$DUCKDB" ] || { echo "missing $DUCKDB — mayhem/build.sh should have built it" >&2; emit_ctrf duckdb-sql 0 1 0; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/duckdb-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

# check <name> <expected stdout> <sql>
check() {
  local name="$1" expected="$2" sql="$3" actual
  actual="$("$DUCKDB" -csv -noheader -c "$sql" 2>&1)"
  if [ "$actual" = "$expected" ]; then passed=$((passed+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name"; echo "  expected: $expected"; echo "  actual:   $actual"; fi
}

# check_error <name> <expected message fragment> <sql>: the statement must fail with that message
check_error() {
  local name="$1" fragment="$2" sql="$3" out rc
  out="$("$DUCKDB" -csv -noheader -c "$sql" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$fragment"; then passed=$((passed+1)); echo "ok   $name"
  else failed=$((failed+1)); echo "FAIL $name (rc=$rc): $out"; fi
}

check arithmetic "2,3.5,3,1024.0,2" "select 1+1, 7/2, 7//2, 2^10, 17%5"
check aggregates "100,5050,50.5,1,100" "select count(*), sum(i), avg(i), min(i), max(i) from range(1,101) t(i)"
check strings "DUCKDB,5,bcd,a+b+c,cba" "select upper('duckdb'), length('hello'), substring('abcdef',2,3), replace('a-b-c','-','+'), reverse('abc')"
check hashes "d41d8cd98f00b204e9800998ecf8427e,ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "select md5(''), sha256('abc')"
check regexp_like "abc#,\"[a, b, c]\",true,3" "select regexp_replace('abc123','[0-9]+','#'), string_split('a,b,c', ','), 'abc' like 'a%', levenshtein('kitten','sitting')"
check window_functions "1,1,NULL
2,3,1
3,6,2
4,10,3
5,15,4" "select i, sum(i) over (order by i), lag(i) over (order by i) from range(1,6) t(i)"
check left_join_group "x,30,2
y,NULL,1
z,30,1" "create table a(k int, v varchar); create table b(k int, w int); insert into a values (1,'x'),(2,'y'),(3,'z'); insert into b values (1,10),(1,20),(3,30); select a.v, sum(b.w), count(*) from a left join b using (k) group by a.v order by a.v"
check order_by "2,a
1,b" "select a, b from (values (1,'b'),(2,'a')) t(a,b) order by b"
check dates "2020-03-01,366,2021/03/04 05:06:07" "select date '2020-02-28' + 2, date_diff('day', date '2020-01-01', date '2021-01-01'), strftime(timestamp '2021-03-04 05:06:07','%Y/%m/%d %H:%M:%S')"
check nested_types "\"[1, 2, 3]\",2,x,a" "select list_sort([3,1,2]), [1,2,3][2], {'a':1,'b':'x'}.b, map {1:'a'}[1]"
check json_functions "\"\"\"x\"\"\",false,true,3" "select json_extract('{\"a\":[1,2,{\"b\":\"x\"}]}', '\$.a[2].b'), json_valid('{\"a\":'), json_valid('[1,2]'), json_array_length('[1,2,3]')"
check_error cast_error "Conversion Error: Could not convert string 'abc' to INT32" "select cast('abc' as integer)"
check_error missing_table "Table with name nonexistent does not exist" "select * from nonexistent"

# Parquet files shipped with upstream (data/parquet-testing)
check parquet_date "36,27,1970-01-01,1997-01-01" "select count(*), count(d), min(d), max(d) from read_parquet('data/parquet-testing/date.parquet')"
check parquet_struct "\"{'str_field': hello, 'f64_field': NULL}\"
\"{'str_field': NULL, 'f64_field': 1.23}\"" "select * from read_parquet('data/parquet-testing/struct.parquet')"
check parquet_float16 "0.0
0.5
1.0
1.5" "select x from read_parquet('data/parquet-testing/float16.parquet') where isfinite(x) order by x"
check parquet_schema "inner,2" "select name, num_children from parquet_schema('data/parquet-testing/struct.parquet') where name = 'inner'"

# Round trips through files written by the program itself
check parquet_roundtrip "1000,499500,10" "copy (select i, i % 10 as g from range(1000) t(i)) to '$WORK/rt.parquet' (format parquet); select count(*), sum(i), count(distinct g) from read_parquet('$WORK/rt.parquet')"
printf 'id,name,score\n1,ann,3.5\n2,"b,ob",4.25\n3,cy,\n' > "$WORK/in.csv"
check csv_auto_detect "3,BIGINT,VARCHAR,DOUBLE" "select count(*), typeof(id), typeof(name), typeof(score) from read_csv('$WORK/in.csv') group by all"
check csv_quoted_field "\"b,ob\",4.25" "select name, score from read_csv('$WORK/in.csv') where id = 2"
check csv_null_sum "7.75" "select sum(score) from read_csv('$WORK/in.csv')"
check csv_roundtrip "3,6" "copy (select i from range(1,4) t(i)) to '$WORK/out.csv' (header); select count(*), sum(i) from read_csv('$WORK/out.csv')"
printf '{"a":1,"b":"x"}\n{"a":2,"b":"y"}\n{"a":3,"b":null}\n' > "$WORK/in.ndjson"
check json_file "3,6,2" "select count(*), sum(a), count(b) from read_json('$WORK/in.ndjson')"

emit_ctrf duckdb-sql "$passed" "$failed" 0
