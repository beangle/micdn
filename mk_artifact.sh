#!/bin/bash
PRGDIR=`dirname "$0"`
export MICDN_HOME=`cd "$PRGDIR" >/dev/null; pwd`
version=`grep "version " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`

mk_artifact(){
  cd $1
  arch=`arch`
  targetName=`grep "targetName " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
  rm -rf target/$targetName-$version-$arch.bin
  mv target/$targetName target/$targetName-$version-$arch.bin
  sha1sum target/$targetName-$version-$arch.bin|awk 'NR==1{gsub(/"/,"");print $1}'>> target/$targetName-$version-$arch.bin.sha1
  mkdir -p ~/.m2/repository/org/beangle/micdn/$targetName/$version/
  rm -rf ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$arch.bin
  cp target/$targetName-$version-$arch.bin ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$arch.bin
  cp target/$targetName-$version-$arch.bin.sha1 ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$arch.bin.sha1
  cd ..
}

dub build --build=release-nobounds --compiler=ldc2
mk_artifact "asset"
mk_artifact "blob"
mk_artifact "maven"

cd $MICDN_HOME
mkdir -p target
rm -rf target/beangle-micdn-$version.zip

cd ~/.m2/repository
zip  $MICDN_HOME/target/beangle-micdn-$version.$arch.zip org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-$arch.bin.sha1 \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-$arch.bin.sha1 \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-$arch.bin.sha1

gpg -ab $MICDN_HOME/target/beangle-micdn-$version.$arch.zip
