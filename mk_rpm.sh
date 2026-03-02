#!/bin/bash
PRGDIR=`dirname "$0"`
export MICDN_HOME=`cd "$PRGDIR" >/dev/null; pwd`

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
    mkdir -p usr/bin etc/micdn usr/lib/systemd/system
    cp -f $MICDN_HOME/target/micdn usr/bin/micdn
    cp -f $MICDN_HOME/deploy/micdn.xml etc/micdn/micdn.xml
    cp -f $MICDN_HOME/deploy/micdn.service usr/lib/systemd/system/micdn.service

    # change folders and files permissions
    chmod -R 0755 .
    chmod 0644 etc/micdn/micdn.xml usr/lib/systemd/system/micdn.service
    chmod 0755 usr/bin/micdn

    # find deb package dependencies
    DEPEND="ldc libpq curl unzip"
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
            # Convert date format to rpm format (Mon Jan 01 2024)
            if [ -n "$DATE_PART" ]; then
              RPM_DATE=$(date -d "$DATE_PART" '+%a %b %d %Y' 2>/dev/null || date '+%a %b %d %Y')
            else
              RPM_DATE=$(date '+%a %b %d %Y')
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
      DATE=$(date '+%a %b %d %Y')
      changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
      changes+="  - Initial release of micdn\n"
      changes+="  - Supports maven, asset, and blob services\n"
      changes+="  - Provides S3 protocol support for blob service\n"
    fi
    # Ensure changelog is not empty and starts with *
    if [ -z "$changes" ]; then
      DATE=$(date '+%a %b %d %Y')
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
    %post
    chown -R micdn:micdn /var/cache/micdn /var/lib/micdn
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

    # Config file: preserve user modifications on upgrade
    echo '%config(noreplace) /etc/micdn/micdn.xml' >> micdn.spec
    # Other files (exclude config already listed)
    find $DESTDIR/$CDNDIR/ ! -type d ! -path '*/etc/micdn/micdn.xml' | \
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
