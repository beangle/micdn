#!/bin/bash
PRGDIR=`dirname "$0"`
export MICDN_HOME=`cd "$PRGDIR" >/dev/null; pwd`
version=`grep "version " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`

mk_artifact(){
  cd $1
  targetName=`grep "targetName " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
  rm -rf target/$targetName-$version-$2.bin
  mv target/$targetName target/$targetName-$version-$2.bin
  sha1sum target/$targetName-$version-$2.bin|awk 'NR==1{gsub(/"/,"");print $1}'>> target/$targetName-$version-$2.bin.sha1
  mkdir -p ~/.m2/repository/org/beangle/micdn/$targetName/$version/
  rm -rf ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$2.bin
  cp target/$targetName-$version-$2.bin ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$2.bin
  cp target/$targetName-$version-$2.bin.sha1 ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$2.bin.sha1
  cd ..
}

dub build --build=release --compiler=ldc2
mk_artifact "asset" "ldc"
mk_artifact "blob" "ldc"
mk_artifact "maven" "ldc"

# dub build --build=release --compiler=dmd
# mk_artifact "asset" "dmd"
# mk_artifact "blob" "dmd"
# mk_artifact "maven" "dmd"

cd $MICDN_HOME
mkdir -p target
rm -rf target/beangle-micdn-$version.zip

cd ~/.m2/repository
zip  $MICDN_HOME/target/beangle-micdn-$version.zip org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-ldc.bin \
org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-ldc.bin.sha1 \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-ldc.bin \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-ldc.bin.sha1 \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-ldc.bin \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-ldc.bin.sha1

gpg -ab $MICDN_HOME/target/beangle-micdn-$version.zip
