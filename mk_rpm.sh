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
  VERSION=`grep "version " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
  MAJOR=$(awk -F. '{ print $1 +0 }' <<<$VERSION)
  MINOR=$(awk -F. '{ print $2 +0 }' <<<$VERSION)
  RELEASE=$(awk -F. '{ print $3 +0 }' <<<$VERSION)
  if [ "$REVISION" == "" ]
  then
    REVISION="1.fc43"
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
    mkdir -p usr/bin
    cp -f $MICDN_HOME/target/micdn usr/bin/micdn

    # change folders and files permissions
    chmod -R 0755 *
    chmod 0644 $(find . ! -type d)
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
    Release: '1.fc43'
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
    %post
    ldconfig || :
    %postun
    ldconfig || :
    %changelog
    '$changes'
    %files' | sed 's/^    //' > micdn.spec

    find $DESTDIR/$CDNDIR/ ! -type d | sed 's:'$DESTDIR'/'$CDNDIR':":' | sed 's:$:":' >> micdn.spec

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

    #rm micdn.spec
  fi
