#!/bin/sh
# 使用 Podman 构建 micdn scratch 镜像：LDC musl 全静态二进制，无 shell / 无 apk / 无调试工具。
# 构建前在仓库根目录执行 dub fetch，并挂载：~/.dub -> /root/.dub；~/.cache/alpine-apk -> /var/cache/apk。
#
# 镜像标签固定为 micdn:<git 最近 tag>-scratch（tag 去掉前缀 v）。
#
# 用法：
#   ./scripts/build_scratch.sh
#
# 环境变量：
#   SKIP_DUB_FETCH=1       跳过宿主机 dub fetch
#   ALPINE_APK_CACHE=路径  apk 缓存目录（默认 $HOME/.cache/alpine-apk）
#   PODMAN_BUILD_EXTRA=…   传给 podman build 的额外选项（如 --no-cache），勿用于改 -t

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "${SKIP_DUB_FETCH:-0}" != "1" ]; then
  if command -v dub >/dev/null 2>&1; then
    echo "build_scratch: running dub fetch in project root ..."
    dub fetch
  else
    echo "build_scratch: dub not in PATH, skipping dub fetch (set SKIP_DUB_FETCH=1 to silence)" >&2
  fi
else
  echo "build_scratch: SKIP_DUB_FETCH=1, skipping dub fetch"
fi

# 版本以 git tag 为唯一来源（如 v0.3.3 -> 0.3.3）。
VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
if [ -z "$VERSION" ]; then
  echo "build_scratch: could not determine version from git tag" >&2
  exit 1
fi

DUB_VOL="-v ${HOME}/.dub:/root/.dub"
APK_CACHE="${ALPINE_APK_CACHE:-$HOME/.cache/alpine-apk}"
mkdir -p "$APK_CACHE"
echo "build_scratch: apk cache dir: $APK_CACHE -> /var/cache/apk"
echo "build_scratch: tag: micdn:${VERSION}-scratch"

# shellcheck disable=SC2086
exec podman build --squash \
  $DUB_VOL \
  -v "$APK_CACHE:/var/cache/apk" \
  -f Dockerfile.scratch \
  -t "micdn:${VERSION}-scratch" \
  $PODMAN_BUILD_EXTRA \
  .
