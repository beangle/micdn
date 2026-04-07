#!/bin/bash
# Debian/Ubuntu 打包脚本。需在 Debian 系系统运行，或安装 dpkg：apt install dpkg-dev fakeroot
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export MICDN_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MICDN_HOME"

set -e -o pipefail
ferror(){
  echo "==========================================================" >&2
  echo $1 >&2
  echo $2 >&2
  echo "==========================================================" >&2
  exit 1
}

dub build --build=release-nobounds --compiler=ldc2

E=0
fcheck(){
  if ! which $1 1>/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck dpkg-deb
fcheck fakeroot
fcheck strip
if [ $E -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

MAINTAINER="duantihua <duantihua@163.com>"
VERSION=`awk -F'"' '/"version"/{print $4; exit}' $MICDN_HOME/dub.json`
REVISION="1"
[[ "$1" == -f ]] && FORCE=1 || { [[ "$1" != "" ]] && REVISION="$1"; }
DESTDIR="$MICDN_HOME/target"
ARCH="amd64"
DEBFILE="micdn_${VERSION}-${REVISION}_${ARCH}.deb"
PKGDIR="$DESTDIR/micdn_${VERSION}-${REVISION}_${ARCH}"

if [ -f "$DESTDIR/$DEBFILE" ] && [ "$FORCE" != "1" ]; then
  echo "$DEBFILE - already exist"
  exit 0
fi

rm -f "$DESTDIR/$DEBFILE"
rm -rf "$PKGDIR"

mkdir -p "$PKGDIR"
pushd "$PKGDIR" > /dev/null

# 文件布局（与 RPM 一致）：默认配置在 /usr/share，卸载 deb 不删除 /etc/micdn/micdn.xml
mkdir -p usr/bin usr/share/micdn usr/lib/systemd/system
cp -f $MICDN_HOME/target/micdn usr/bin/micdn
strip --strip-unneeded usr/bin/micdn
cp -f $MICDN_HOME/scripts/package/micdn.xml usr/share/micdn/micdn.xml.default
cp -f $MICDN_HOME/scripts/package/micdn.service usr/lib/systemd/system/micdn.service

chmod 0755 usr/bin/micdn
chmod 0644 usr/share/micdn/micdn.xml.default usr/lib/systemd/system/micdn.service

# DEBIAN 控制文件
mkdir -p DEBIAN

# control
cat > DEBIAN/control << EOF
Package: micdn
Version: ${VERSION}-${REVISION}
Section: web
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Depends: curl
Description: Beangle Minimal CDN Server
 Mini CDN, serve static resource, maven artifacts and binary file storage.
 . 
 Main designer: Duan TiHua
EOF

# 不设 conffiles：/etc/micdn/micdn.xml 由 postinst 从 default 生成，不由包跟踪，卸载时保留

# preinst：创建用户和目录
cat > DEBIAN/preinst << 'PREINST'
#!/bin/sh
set -e
if ! getent group beangle >/dev/null 2>&1; then
  addgroup --system beangle
fi
if ! getent passwd micdn >/dev/null 2>&1; then
  adduser --system --ingroup beangle --home /var/lib/micdn --no-create-home --disabled-login micdn 2>/dev/null || \
  useradd -r -g beangle -d /var/lib/micdn -s /usr/sbin/nologin -c "Micdn CDN server" micdn
else
  usermod -g beangle micdn 2>/dev/null || true
fi
mkdir -p /var/cache/micdn/asset /var/cache/micdn/www
mkdir -p /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
mkdir -p /var/log/micdn
PREINST

# postinst：首次生成配置、数据目录权限（与 RPM %post 一致）、重载 systemd
cat > DEBIAN/postinst << 'POSTINST'
#!/bin/sh
set -e
mkdir -p /etc/micdn
if [ ! -f /etc/micdn/micdn.xml ]; then
  cp -f /usr/share/micdn/micdn.xml.default /etc/micdn/micdn.xml
  chmod 0644 /etc/micdn/micdn.xml
fi
chown -R micdn:beangle /var/cache/micdn /var/lib/micdn /var/log/micdn
chmod 2775 /var/cache/micdn /var/cache/micdn/asset /var/cache/micdn/www
chmod 2775 /var/lib/micdn /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
chmod 2775 /var/log/micdn
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTINST

# prerm：卸载前停止服务
cat > DEBIAN/prerm << 'PRERM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop micdn 2>/dev/null || true
fi
PRERM

# postrm：卸载后重载 systemd
cat > DEBIAN/postrm << 'POSTRM'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTRM

chmod 0555 DEBIAN/preinst DEBIAN/postinst DEBIAN/prerm DEBIAN/postrm

popd > /dev/null

# 构建 deb 包（-Zxz 压缩，不支持则用默认）
fakeroot dpkg-deb --build -Zxz "$PKGDIR" "$DESTDIR/$DEBFILE" 2>/dev/null || \
fakeroot dpkg-deb --build "$PKGDIR" "$DESTDIR/$DEBFILE"

rm -rf "$PKGDIR"

echo "Built: $DESTDIR/$DEBFILE"
