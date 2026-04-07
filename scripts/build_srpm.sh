#!/bin/bash
# 生成源代码 SRPM（.src.rpm），内含源码 tarball 与 spec；可在其它机器用
#   rpmbuild --rebuild micdn-*.src.rpm
# 或 mock/koji 重编二进制 RPM。需网络：%build 中 dub fetch 拉依赖。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export MICDN_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MICDN_HOME"

set -e -o pipefail

ferror() {
  echo "==========================================================" >&2
  echo "$1" >&2
  echo "$2" >&2
  echo "==========================================================" >&2
  exit 1
}

sys_release_version() {
  local os_id
  os_id=$(source /etc/os-release && echo "$ID")
  if [ "$os_id" == "fedora" ]; then
    REVISION="1.fc$(source /etc/os-release && echo "$VERSION_ID")"
  else
    REVISION="1.el$(source /etc/os-release && echo "$VERSION_ID")"
  fi
}

E=0
LIST=""
fcheck() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck gzip
fcheck rpmbuild
fcheck tar
if [ "$E" -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

MAINTAINER="duantihua <duantihua@163.com>"
VERSION_RAW=$(awk -F'"' '/"version"/{print $4; exit}' "$MICDN_HOME/dub.json")
# 与 build_rpm.sh 一致：RPM Version 中预发布号用 ~（仅替换首段 -）
VERSION_RPM=$(sed 's/-/~/' <<<"$VERSION_RAW")
REVISION=""
sys_release_version

DESTDIR="$MICDN_HOME/target"
RPMDIR="$DESTDIR/rpmbuild-src"
SRPMFILE="micdn-${VERSION_RPM}-${REVISION}.src.rpm"
FORCE=0
[[ "$1" == "-f" ]] && FORCE=1

if [[ -f "$DESTDIR/$SRPMFILE" && "$FORCE" != "1" ]]; then
  echo "$SRPMFILE - already exist (use -f to rebuild)"
  exit 0
fi

rm -rf "$RPMDIR"
mkdir -p "$RPMDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# 源码包：顶层目录名须为 %{name}-%{version}，供 %%setup -q 使用
(
  cd "$(dirname "$MICDN_HOME")" || exit 1
  tar czf "$RPMDIR/SOURCES/micdn-${VERSION_RPM}.tar.gz" \
    --exclude='micdn/.git' \
    --exclude='micdn/target' \
    --exclude='micdn/.dub' \
    --exclude='micdn/.cursor' \
    --transform="s,^micdn,micdn-${VERSION_RPM}," \
    micdn
)

# %%changelog（与 build_rpm.sh 一致：LC_ALL=C 避免中文 locale 下日期非法）
changes=""
if [ -f "$MICDN_HOME/CHANGELOG.md" ]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^##\ v ]]; then
      VERSION_INFO=$(echo "$line" | sed 's/## v//')
      VERSION_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 1)
      DATE_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 2 | sed 's/[()]//g')
      if [ -n "$DATE_PART" ]; then
        RPM_DATE=$(LC_ALL=C date -d "$DATE_PART" '+%a %b %d %Y' 2>/dev/null || LC_ALL=C date '+%a %b %d %Y')
      else
        RPM_DATE=$(LC_ALL=C date '+%a %b %d %Y')
      fi
      changes+="* $RPM_DATE $MAINTAINER - ${VERSION_PART}"$'\n'
    elif [[ "$line" =~ ^- ]]; then
      changes+="  ${line}"$'\n'
    fi
  done < "$MICDN_HOME/CHANGELOG.md"
else
  DATE=$(LC_ALL=C date '+%a %b %d %Y')
  changes="* $DATE $MAINTAINER - ${VERSION_RPM}-${REVISION}"$'\n'
  changes+="  - micdn source package"$'\n'
fi
if [ -z "$changes" ]; then
  DATE=$(LC_ALL=C date '+%a %b %d %Y')
  changes="* $DATE $MAINTAINER - ${VERSION_RPM}-${REVISION}"$'\n'
  changes+="  - No changelog available"$'\n'
fi

cat > "$RPMDIR/SPECS/micdn.spec" << EOF
Name: micdn
Version: ${VERSION_RPM}
Release: ${REVISION}
Summary: Beangle Minimal CDN Server
License: GPLv3+
URL: https://github.com/beangle/micdn
Source0: %{name}-%{version}.tar.gz
# 重编二进制时：ldc、dub 等；CentOS7 上 ldc/dub 可能来自 EPEL/第三方仓库
BuildRequires: ldc dub git gcc make zlib-devel openssl-devel curl binutils
# 运行时：二进制不依赖 ldc 包；curl 为 micdn 下载/调用外部 curl 所需
Requires: curl

%description
Mini CDN: static assets, Maven, NPM, blob storage with optional S3-compatible API.
Main designer: Duan TiHua

%prep
%setup -q

%build
export DUB_HOME="\${DUB_HOME:-\$HOME/.dub}"
dub fetch
dub build --build=release-nobounds --compiler=ldc2

%install
rm -rf %{buildroot}
install -D -m 0755 target/micdn %{buildroot}/usr/bin/micdn
strip --strip-unneeded %{buildroot}/usr/bin/micdn
install -D -m 0644 scripts/package/micdn.xml %{buildroot}/etc/micdn/micdn.xml
install -D -m 0644 scripts/package/micdn.service %{buildroot}/usr/lib/systemd/system/micdn.service

%pre
getent group micdn >/dev/null 2>&1 || groupadd -r micdn
getent passwd micdn >/dev/null 2>&1 || useradd -r -g micdn -d /var/lib/micdn -s /sbin/nologin -c "Micdn CDN server" micdn
mkdir -p /var/cache/micdn/asset /var/cache/micdn/www
mkdir -p /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
mkdir -p /var/log/micdn

%post
chown -R micdn:micdn /var/cache/micdn /var/lib/micdn /var/log/micdn
systemctl daemon-reload 2>/dev/null || :

%preun
if [ "\$1" = 0 ]; then
  systemctl stop micdn 2>/dev/null || :
fi

%postun
systemctl daemon-reload 2>/dev/null || :

%files
%attr(0755,root,root) /usr/bin/micdn
%config(noreplace) %attr(0644,root,root) /etc/micdn/micdn.xml
%attr(0644,root,root) /usr/lib/systemd/system/micdn.service

%changelog
$(printf '%b' "$changes")
EOF

rpmbuild --define "_topdir $RPMDIR" -bs "$RPMDIR/SPECS/micdn.spec"

mv -f "$RPMDIR/SRPMS/$SRPMFILE" "$DESTDIR/$SRPMFILE"
rm -rf "$RPMDIR"

echo "SRPM: $DESTDIR/$SRPMFILE"
