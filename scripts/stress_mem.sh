#!/usr/bin/env bash
# 多文件内存压测：生成多文件 www 样例（zip 部署），跑 c=50 多路径 + heavy c=200 大文件，
# 输出各阶段 RSS/HWM；可选 --reclaim 调用 /admin/reclaim 验证按需回收。
#
# 用法:
#   scripts/stress_mem.sh                    # 默认端口 8901，不回收
#   scripts/stress_mem.sh -p 8901 --reclaim
#
# 选项:
#   -p PORT     服务端口（默认 8901）
#   -d DIR      样例/工作目录（默认 /tmp/micdn-stress-many）
#   --reclaim   heavy 后调用 /admin/reclaim 并输出回收后 RSS
#   -h          帮助
#
# 样例规模（可用 -s/-m/-b 调整）:
#   small  2-4KB x 2000（assets/part_*.js）
#   medium 50-100KB x 150（assets/medium_*.js）
#   big    300KB-2.2MB x 24（lib/big_*.js）
#
# 坑:
#   - ab 的 URL 必须是最后一个参数（-n/-c/-H 在前）
#   - 样例内容用随机数字控制 zip 压缩比，避免触发 maxZipCompressionRatio 拒部署
#   - 内存读 /proc/<pid>/status 的 VmRSS/VmHWM（kB）

set -euo pipefail

PORT=8901
DIR=/tmp/micdn-stress-many
RECLAIM=0
SMALL=2000
MEDIUM=150
BIG=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PORT="$2"; shift 2 ;;
    -d) DIR="$2"; shift 2 ;;
    --reclaim) RECLAIM=1; shift ;;
    -h) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/target/micdn"
BASE="http://127.0.0.1:$PORT/manual"
OUT="$DIR/mem_result.txt"

for cmd in python3 zip ab curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found" >&2; exit 1; }
done
[[ -x "$BIN" ]] || { echo "error: build first: dub build --build=release-nobounds --compiler=ldc2" >&2; exit 1; }

snapshot() {
  local label="$1"
  local pid="$2"
  local rss hwm
  rss=$(awk '/VmRSS:/{print $2}' "/proc/$pid/status")
  hwm=$(awk '/VmHWM:/{print $2}' "/proc/$pid/status")
  echo "[$label] RSS=${rss}kB HWM=${hwm}kB" | tee -a "$OUT"
}

echo "### stress_mem env" | tee "$OUT"
echo "  date: $(date '+%F %T')  commit: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)" | tee -a "$OUT"
echo "  port=$PORT dir=$DIR small=$SMALL medium=$MEDIUM big=$BIG reclaim=$RECLAIM" | tee -a "$OUT"

# ---- 生成样例 ----
echo "generating samples ($SMALL small + $MEDIUM medium + $BIG big) ..."
rm -rf "$DIR"
mkdir -p "$DIR/src/dist/assets" "$DIR/src/dist/lib"
python3 - "$DIR" "$SMALL" "$MEDIUM" "$BIG" <<'PY'
import os, random, sys
base, small, medium, big = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rnd = random.Random(42)
def gen(path, target_kb):
    with open(path, "w") as f:
        n = max(1, int(target_kb * 1024 / 60))
        for i in range(n):
            f.write("var k%02d=%d;/*%s*/\n" % (rnd.randrange(20), rnd.getrandbits(32), "x" * 40))
for i in range(small):
    gen(os.path.join(base, "src/dist/assets", "part_%04d.js" % i), rnd.uniform(2, 4))
for i in range(medium):
    gen(os.path.join(base, "src/dist/assets", "medium_%03d.js" % i), rnd.uniform(50, 100))
for i in range(big):
    gen(os.path.join(base, "src/dist/lib", "big_%02d.js" % i), rnd.uniform(300, 2200))
with open(os.path.join(base, "src/dist/index.html"), "w") as f:
    f.write("<!doctype html><html><head><title>manual</title></head><body><h1>stress mem</h1></body></html>\n")
PY
(cd "$DIR/src" && zip -qr "$DIR/manual.zip" dist)

cat > "$DIR/micdn.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<micdn home="$DIR/home" listen="127.0.0.1:$PORT">
  <www base="$DIR/www">
    <doc name="manual" zip="$DIR/manual.zip" inner="dist" try-file="index.html" />
  </www>
</micdn>
XML

# ---- 启动 ----
setsid nohup "$BIN" -f "$DIR/micdn.xml" > "$DIR/micdn.log" 2>&1 < /dev/null &
SRV_PID=$!
for _ in $(seq 1 50); do
  if grep -q "Listening for requests" "$DIR/micdn.log" 2>/dev/null; then break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then echo "server failed to start"; tail -5 "$DIR/micdn.log"; exit 1; fi
  sleep 0.2
done
grep -q "Listening for requests" "$DIR/micdn.log" || { echo "server not ready"; tail -5 "$DIR/micdn.log"; exit 1; }
snapshot "startup" "$SRV_PID"

# ---- c=50 多路径 ----
echo "running c=50 multi-path (sampled small + all medium/big + dir + 404) ..."
C50_URLS=()
for i in $(seq -w 0 9 1999); do C50_URLS+=("assets/part_0$i.js"); done
for i in $(seq -w 0 149); do C50_URLS+=("assets/medium_0$i.js"); done
for i in $(seq -w 0 23); do C50_URLS+=("lib/big_$i.js"); done
C50_URLS+=("" "nope.js")
for u in "${C50_URLS[@]}"; do
  ab -k -r -n 200 -c 50 "$BASE/$u" > /dev/null 2>&1 || true
done
snapshot "c50" "$SRV_PID"

# ---- heavy c=200 ----
echo "running heavy c=200 (big/medium/gzip/404) ..."
for f in lib/big_03.js lib/big_06.js lib/big_12.js; do
  ab -k -r -n 1000 -c 200 "$BASE/$f" > /dev/null 2>&1 || true
done
for f in assets/medium_000.js assets/medium_149.js; do
  ab -k -r -n 2000 -c 200 "$BASE/$f" > /dev/null 2>&1 || true
done
ab -k -r -n 500 -c 100 -H 'Accept-Encoding: gzip' "$BASE/lib/big_03.js" > /dev/null 2>&1 || true
ab -k -r -n 2000 -c 200 "$BASE/nope.js" > /dev/null 2>&1 || true
snapshot "heavy" "$SRV_PID"

# ---- 可选 reclaim ----
if [[ "$RECLAIM" == 1 ]]; then
  echo "calling /admin/reclaim ..."
  curl -s "http://127.0.0.1:$PORT/admin/reclaim" | tee -a "$OUT"
  echo >> "$OUT"
  snapshot "reclaimed" "$SRV_PID"
fi

kill "$SRV_PID" 2>/dev/null || true
echo "done -> $OUT"
