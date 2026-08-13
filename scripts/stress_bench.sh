#!/usr/bin/env bash
# 四场景吞吐压测（对齐 docs/stress_test.md 复现方法：预热 N 轮 + M 轮取中位）。
#
# 用法:
#   scripts/stress_bench.sh                     # 默认 http://127.0.0.1:8899
#   scripts/stress_bench.sh -p 8899 -c 100 -n 10000
#   scripts/stress_bench.sh -o /tmp/stress.txt http://127.0.0.1:8899
#
# 选项:
#   -p PORT  服务端口（默认 8899，仅在本机探测时使用）
#   -c CONC   并发数（默认 100）
#   -n TOTAL  每轮请求总数（默认 10000）
#   -w WARM   预热轮数（默认 5，每轮 1000 请求）
#   -r RUNS   正式轮数（默认 3）
#   -o OUT    输出文件（默认 /tmp/stress-bench.txt）
#   BASE_URL  被测基础地址（默认 http://127.0.0.1:8899，可带 doc 前缀如 http://127.0.0.1:8899/manual）
#
# 覆盖场景（URL 相对 BASE_URL）:
#   dir_index  目录 -> index.html（keep-alive）
#   file_hit   文件命中（keep-alive）
#   404        未命中（不带 keep-alive，ab -k 会对非 2xx 计 Length 失败）
#   gzip_hit   gzip 命中（keep-alive + Accept-Encoding: gzip）
#
# 坑（本仓库历次压测踩过）:
#   - ab 的 URL 必须是最后一个参数：-n/-c/-H 等选项写在前，否则报
#     "ab: wrong number of arguments"
#   - 解析用 awk（grep -oP 在部分环境不可用）
#   - 比较 RPS 前先记录 CPU 频率（scaling_cur_freq）与 load，频率不同不可直接比

set -euo pipefail

PORT=8899
CONC=100
TOTAL=10000
WARM=5
RUNS=3
OUT=/tmp/stress-bench.txt
BASE="http://127.0.0.1:8899"

while getopts ':p:c:n:w:r:o:h' opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    c) CONC="$OPTARG" ;;
    n) TOTAL="$OPTARG" ;;
    w) WARM="$OPTARG" ;;
    r) RUNS="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [[ $# -ge 1 ]]; then
  BASE="$1"
fi

for cmd in ab awk curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found" >&2; exit 1; }
done

freq() {
  local f
  f=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo n/a)
  echo "${f} kHz"
}

: > "$OUT"
echo "### env" | tee -a "$OUT"
echo "  date: $(date '+%F %T')" | tee -a "$OUT"
echo "  commit: $(git rev-parse --short HEAD 2>/dev/null || echo n/a)" | tee -a "$OUT"
echo "  freq: $(freq)  load: $(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$OUT"
echo "  base: $BASE  conc=$CONC  total=$TOTAL  warm=$WARM  runs=$RUNS" | tee -a "$OUT"

run_scene() {
  local name="$1"; shift
  local url="$1"; shift
  local extra=("$@")   # 额外 ab 选项，如 -H 'Accept-Encoding: gzip'
  echo "### $name $url" | tee -a "$OUT"
  local i
  for i in $(seq 1 "$WARM"); do
    ab "${extra[@]}" -r -n 1000 -c "$CONC" "$BASE$url" > /dev/null 2>&1 || true
  done
  local vals=()
  for i in $(seq 1 "$RUNS"); do
    local out
    out=$(ab "${extra[@]}" -r -n "$TOTAL" -c "$CONC" "$BASE$url" 2>&1)
    local rps p99 fail
    rps=$(echo "$out" | awk '/Requests per second:/{print $4; exit}')
    p99=$(echo "$out" | awk '/^ *99%/{print $2; exit}')
    fail=$(echo "$out" | awk '/Failed requests:/{print $3; exit}')
    echo "  run$i rps=$rps p99=$p99 failed=$fail" | tee -a "$OUT"
    vals+=("$rps")
  done
  # 中位 RPS
  local med
  med=$(printf '%s\n' "${vals[@]}" | sort -n | awk -v n="$RUNS" 'NR==int((n+1)/2){print; exit}')
  echo "  median_rps=$med" | tee -a "$OUT"
}

run_scene "dir_index" "/manual/" -k
run_scene "file_hit"  "/manual/app.js" -k
run_scene "404"       "/manual/nope.js"
run_scene "gzip_hit"  "/manual/app.js" -k -H 'Accept-Encoding: gzip'

echo "### env-after" | tee -a "$OUT"
echo "  freq: $(freq)  load: $(cut -d' ' -f1-3 /proc/loadavg)" | tee -a "$OUT"
echo "done -> $OUT"
