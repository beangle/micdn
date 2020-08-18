#!/bin/bash
PRGDIR=`dirname "$0"`
export MICDN_HOME=`cd "$PRGDIR" >/dev/null; pwd`
version=`grep "version " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`

mk_artifact(){
  cd $1
  targetName=`grep "targetName " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
  rm -rf target/$targetName-$version-$2.bin
  mv target/$targetName target/$targetName-$version-$2.bin
  mkdir -p ~/.m2/repository/org/beangle/micdn/$targetName/$version/
  cp target/$targetName-$version-$2.bin ~/.m2/repository/org/beangle/micdn/$targetName/$version/$targetName-$version-$2.bin
  cd ..
}

dub build --build=release --compiler=ldc2
mk_artifact "asset" "ldc"
mk_artifact "blob" "ldc"
mk_artifact "maven" "ldc"

cd $MICDN_HOME
mkdir -p target
rm -rf target/beangle-micdn-$version.zip

zip -j target/beangle-micdn-$version.zip asset/target/beangle-micdn-asset-$version-ldc.bin blob/target/beangle-micdn-blob-$version-ldc.bin maven/target/beangle-micdn-maven-$version-ldc.bin
