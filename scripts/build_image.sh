#!/bin/sh
# 使用 Podman 构建 micdn 镜像（Alpine / musl），默认带 --squash；构建前在仓库根目录执行 dub fetch，
# 并挂载：~/.dub → /root/.dub；~/.cache/alpine-apk → /var/cache/apk。
#
# 镜像标签固定为 micdn:<dub.json 的 "version">，不接受命令行改 tag。
#
# 用法：
#   ./scripts/build_image.sh
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
    echo "build_image: running dub fetch in project root ..."
    dub fetch
  else
    echo "build_image: dub not in PATH, skipping dub fetch (set SKIP_DUB_FETCH=1 to silence)" >&2
  fi
else
  echo "build_image: SKIP_DUB_FETCH=1, skipping dub fetch"
fi

VERSION="$(awk -F'"' '/"version"/{print $4; exit}' dub.json)"
if [ -z "$VERSION" ]; then
  echo "build_image: could not read version from dub.json" >&2
  exit 1
fi

DUB_VOL="-v ${HOME}/.dub:/root/.dub"
APK_CACHE="${ALPINE_APK_CACHE:-$HOME/.cache/alpine-apk}"
mkdir -p "$APK_CACHE"
echo "build_image: apk cache dir: $APK_CACHE -> /var/cache/apk"
echo "build_image: tag: micdn:${VERSION}"

# shellcheck disable=SC2086
exec podman build --squash \
  $DUB_VOL \
  -v "$APK_CACHE:/var/cache/apk" \
  -f Dockerfile \
  -t "micdn:${VERSION}" \
  $PODMAN_BUILD_EXTRA \
  .
