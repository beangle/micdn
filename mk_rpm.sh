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
dub build --build=release --compiler=ldc2

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
    REVISION="1.fc32"
  fi
  DESTDIR="$MICDN_HOME/target"
  VERSION=$(sed 's/-/~/' <<<$VERSION) # replace dash by tilde
  ARCH="x86_64"
  FARCH="x86-64"

  CDNDIR="beangle-micdn-"$VERSION"-"$REVISION"."$ARCH
  RPMFILE="beangle-micdn-"$VERSION"-"$REVISION"."$ARCH".rpm"
  RPMDIR=$DESTDIR"/rpmbuild"

echo $MICDN_HOME
  # check if destination rpm file already exist
  if [ -f $DESTDIR"/"$RPMFILE ] && `rpm -qip $DESTDIR"/"$RPMFILE &>/dev/null` && test "$1" != "-f" ;then
    echo -e "$RPMFILE - already exist"
  else
    rm -f $DESTDIR"/"$RPMFILE
    rm -rf  $DESTDIR"/"$CDNDIR
    # create temp dir
    mkdir -p $DESTDIR"/"$CDNDIR
    # switch to temp dir
    pushd $DESTDIR"/"$CDNDIR
    mkdir -p usr/bin
    cp -f $MICDN_HOME/asset/target/beangle-micdn-asset usr/bin/micdn-asset
    cp -f $MICDN_HOME/blob/target/beangle-micdn-blob usr/bin/micdn-blob
    cp -f $MICDN_HOME/maven/target/beangle-micdn-maven usr/bin/micdn-maven

    # install libraries
    A_LIB="libbeangle-micdn-core.a"
    mkdir -p usr/lib64
    cp -f $MICDN_HOME/core/target/libbeangle-micdn-core.a usr/lib64

    mkdir -p usr/share/doc/micdn
    cat $MICDN_HOME/LICENSE | sed 's/\r//' >> usr/share/doc/micdn/copyright

    # change folders and files permissions
    chmod -R 0755 *
    chmod 0644 $(find . ! -type d)
    chmod 0755 usr/bin/{micdn-asset,micdn-blob,micdn-maven}

    # find deb package dependencies
    DEPEND="ldc($FARCH)"
    # create micdn.spec file
    cd ..
    echo -e 'Name: beangle-micdn
    Version: '$VERSION'
    Release: '1.fc32'
    Summary: Beangle Minimal CDN Server
    Group: Development/System
    License: see /usr/share/doc/micdn/copyright
    URL: http://github.io/beangle/micdn
    Packager: '$MAINTAINER'
    ExclusiveArch: '$ARCH'
    Requires: '$DEPEND'
    Provides: micdn-asset('$FARCH') = '$VERSION-$REVISION', micdn-blob('$FARCH') = '$VERSION-$REVISION', micdn-maven('$FARCH') = '$VERSION-$REVISION'
    %description
    Mini cdn,serve static resource, maven artifacts and binary file storage.
    Main designer: Duan TiHua
    %post
    ldconfig || :
    %postun
    ldconfig || :
    %files' | sed 's/^    //' > micdn.spec

    find $DESTDIR/$CDNDIR/ ! -type d | sed 's:'$DESTDIR'/'$CDNDIR':":' | sed 's:$:":' >> micdn.spec

    echo >> micdn.spec
    mkdir -p $RPMDIR
    echo "%define _rpmdir $RPMDIR" >> micdn.spec
    # create rpm file
    fakeroot rpmbuild --quiet --buildroot=$DESTDIR/$CDNDIR -bb --target $ARCH --define '_binary_payload w9.xzdio' micdn.spec

    # disable pushd
    popd

    # place rpm package
    mv $RPMDIR/$ARCH/beangle-micdn-$VERSION-$REVISION.$ARCH.rpm $DESTDIR"/"$RPMFILE

    # delete temp dir
    rm -Rf $RPMDIR
  fi
