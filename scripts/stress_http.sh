#!/usr/bin/env bash
# HTTP 压力测试：默认并发 100、总请求 10000。
# 依赖 ApacheBench (ab)。安装：sudo dnf install httpd-tools
# 示例：
#   ./scripts/stress_http.sh
#   ./scripts/stress_http.sh -c 200 -n 20000 'http://local.openurp.net/static/my97/4.8.5/WdatePicker.js'

set -euo pipefail

CONCURRENCY=100
TOTAL=10000
URL='http://local.openurp.net/static/my97/4.8.5/WdatePicker.js'

usage() {
  cat <<'EOF'
Usage: stress_http.sh [-c CONCURRENCY] [-n TOTAL] [URL]

  -c  并发数（默认 100）
  -n  总请求数（默认 10000）
  URL 目标地址（默认可改脚本内 URL）
EOF
}

while getopts ':c:n:h' opt; do
  case "$opt" in
    c) CONCURRENCY="$OPTARG" ;;
    n) TOTAL="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -ge 1 ]]; then
  URL="$1"
fi

if ! command -v ab >/dev/null 2>&1; then
  echo "error: ab (ApacheBench) not found. Install: sudo dnf install httpd-tools" >&2
  exit 1
fi

echo "==> Warmup (1 request)"
curl -sf -o /dev/null "$URL" || {
  echo "error: warmup failed for $URL" >&2
  exit 1
}

echo "==> Stress test"
echo "    URL:         $URL"
echo "    Concurrency: $CONCURRENCY"
echo "    Total:       $TOTAL"
echo

# -k 复用 keep-alive；-r 遇 socket 错误时不退出（高并发下更稳）
ab -k -r -n "$TOTAL" -c "$CONCURRENCY" "$URL"
