#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export MICDN_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$MICDN_HOME"

set -e -o pipefail
# error function
ferror(){
  echo "==========================================================" >&2
  echo $1 >&2
  echo $2 >&2
  echo "==========================================================" >&2
  exit 1
}
sys_release_version(){
  local os_id
  os_id=$(source /etc/os-release && echo "$ID")
  if [ "$os_id" == "fedora" ]; then
    REVISION="1.fc$(source /etc/os-release && echo "$VERSION_ID")"
  else
    REVISION="1.el$(source /etc/os-release && echo "$VERSION_ID")"
  fi
}


dub build --build=release-nobounds --compiler=ldc2

# needed commands function
E=0
fcheck(){
  if ! `which $1 1>/dev/null 2>&1` ;then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck gzip
fcheck rpmbuild
fcheck fakeroot
fcheck strip
if [ $E -eq 1 ]; then
    ferror "Missing commands on Your system:" "$LIST"
fi

  # assign variables
  MAINTAINER="duantihua <duantihua@163.com>"
  VERSION=`awk -F'"' '/"version"/{print $4; exit}' $MICDN_HOME/dub.json`
  MAJOR=$(awk -F. '{ print $1 +0 }' <<<$VERSION)
  MINOR=$(awk -F. '{ print $2 +0 }' <<<$VERSION)
  RELEASE=$(awk -F. '{ print $3 +0 }' <<<$VERSION)
  if [ "$REVISION" == "" ]
  then
    sys_release_version
  fi
  DESTDIR="$MICDN_HOME/target"
  VERSION=$(sed 's/-/~/' <<<$VERSION) # replace dash by tilde
  ARCH="x86_64"

  CDNDIR="micdn-"$VERSION"-"$REVISION"."$ARCH
  RPMFILE="micdn-"$VERSION"-"$REVISION"."$ARCH".rpm"
  RPMDIR=$DESTDIR"/rpmbuild"

  # check if destination rpm file already exist
  if [ -f $DESTDIR"/"$RPMFILE ] && `rpm -qip $DESTDIR"/"$RPMFILE &>/dev/null` && test "$1" != "-f" ;then
    echo -e "$RPMFILE - already exist"
  else
    rm -f $DESTDIR"/"$RPMFILE
    rm -rf  $DESTDIR"/"$CDNDIR
    # create temp dir
    mkdir -p $DESTDIR"/"$CDNDIR
    # switch to temp dir
    pushd $DESTDIR"/"$CDNDIR > /dev/null
    mkdir -p usr/bin usr/share/micdn usr/lib/systemd/system
    cp -f $MICDN_HOME/target/micdn usr/bin/micdn
    strip --strip-unneeded usr/bin/micdn
    # 默认配置放在 /usr/share，由 %%post 首次安装时复制到 /etc/micdn/micdn.xml，卸载时不删除用户配置
    cp -f $MICDN_HOME/scripts/package/micdn.xml usr/share/micdn/micdn.xml.default
    cp -f $MICDN_HOME/scripts/package/micdn.service usr/lib/systemd/system/micdn.service

    # change folders and files permissions
    chmod -R 0755 .
    chmod 0644 usr/share/micdn/micdn.xml.default usr/lib/systemd/system/micdn.service
    chmod 0755 usr/bin/micdn

    # 运行时依赖：ldc 仅在构建机需要（dub build），安装包的目标机无需 ldc（ldd 通常无 ldc.so）
    DEPEND="curl"
    # create micdn.spec file
    cd ..
    # Generate changelog
    changes=""
    if [ -f "$MICDN_HOME/CHANGELOG.md" ]; then
      # Read changelog from file
      while IFS= read -r line; do
        if [[ "$line" =~ ^##\ v ]]; then
            # Extract version and date
            VERSION_INFO=$(echo "$line" | sed 's/## v//')
            VERSION_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 1)
            DATE_PART=$(echo "$VERSION_INFO" | cut -d ' ' -f 2 | sed 's/[()]//g')
            # RPM %changelog 要求英文星期/月份；须 LC_ALL=C，否则中文环境会得到「三 1月…」而 rpmbuild 报错
            if [ -n "$DATE_PART" ]; then
              RPM_DATE=$(LC_ALL=C date -d "$DATE_PART" '+%a %b %d %Y' 2>/dev/null || LC_ALL=C date '+%a %b %d %Y')
            else
              RPM_DATE=$(LC_ALL=C date '+%a %b %d %Y')
            fi
            # Add changelog header with * prefix
            changes+="* $RPM_DATE $MAINTAINER - ${VERSION_PART}\n"

        elif [[ "$line" =~ ^- ]]; then
            # Add changelog entry with proper indentation
            changes+="  ${line}\n"
        fi
      done < "$MICDN_HOME/CHANGELOG.md"
    else
      # Default changelog with * prefix
      DATE=$(LC_ALL=C date '+%a %b %d %Y')
      changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
      changes+="  - Initial release of micdn\n"
      changes+="  - Supports maven, asset, and blob services\n"
      changes+="  - Provides S3 protocol support for blob service\n"
    fi
    # Ensure changelog is not empty and starts with *
    if [ -z "$changes" ]; then
      DATE=$(LC_ALL=C date '+%a %b %d %Y')
      changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
      changes+="  - No changelog available\n"
    fi

    echo -e 'Name: micdn
    Version: '$VERSION'
    Release: '$REVISION'
    Summary: Beangle Minimal CDN Server
    Group: Development/System
    License: GPLv3+
    URL: http://github.io/beangle/micdn
    Packager: '$MAINTAINER'
    ExclusiveArch: '$ARCH'
    Requires: '$DEPEND'
    Provides: micdn('$ARCH') = '$VERSION-$REVISION'
    %description
    Mini cdn,serve static resource, maven artifacts and binary file storage.
    Main designer: Duan TiHua
    %pre
    getent group micdn >/dev/null 2>&1 || groupadd -r micdn
    getent passwd micdn >/dev/null 2>&1 || useradd -r -g micdn -d /var/lib/micdn -s /sbin/nologin -c "Micdn CDN server" micdn
    mkdir -p /var/cache/micdn/asset /var/cache/micdn/www
    mkdir -p /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
    mkdir -p /var/log/micdn
    %post
    mkdir -p /etc/micdn
    if [ ! -f /etc/micdn/micdn.xml ]; then
      cp -f /usr/share/micdn/micdn.xml.default /etc/micdn/micdn.xml
      chmod 0644 /etc/micdn/micdn.xml
    fi
    chown -R micdn:micdn /var/cache/micdn /var/lib/micdn /var/log/micdn
    # 组可读写 + setgid，便于加入 micdn 组的管理员维护；配合 UMask=0002 使新文件对组可写
    chmod 2775 /var/cache/micdn /var/cache/micdn/asset /var/cache/micdn/www
    chmod 2775 /var/lib/micdn /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
    chmod 2775 /var/log/micdn
    systemctl daemon-reload 2>/dev/null || :
    %preun
    if [ "$1" = 0 ]; then
      systemctl stop micdn 2>/dev/null || :
    fi
    %postun
    systemctl daemon-reload 2>/dev/null || :
    %changelog
    '$changes'
    %files' | sed 's/^    //' > micdn.spec

    # /etc/micdn/micdn.xml 不在 %%files 中，卸载 rpm 时保留配置与 /var 下数据目录
    find $DESTDIR/$CDNDIR/ ! -type d | \
      sed 's|'$DESTDIR'/'$CDNDIR'|/|' >> micdn.spec

    echo >> micdn.spec
    mkdir -p $RPMDIR
    echo "%define _rpmdir $RPMDIR" >> micdn.spec
    # create rpm file
    fakeroot rpmbuild --quiet --buildroot=$DESTDIR/$CDNDIR -bb --target $ARCH --define '_binary_payload w9.xzdio' micdn.spec

    # disable pushd
    popd > /dev/null
    # place rpm package
    mv $RPMDIR/$ARCH/micdn-$VERSION-$REVISION.$ARCH.rpm $DESTDIR"/"$RPMFILE

    # delete temp dir
    rm -Rf $RPMDIR
    rm -Rf $DESTDIR"/"$CDNDIR
    rm -Rf $DESTDIR/micdn.spec

  fi
