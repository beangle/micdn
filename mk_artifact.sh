#!/bin/bash
set -e
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

system_version() {
  if [ ! -f "/etc/os-release" ]; then
    echo "Error: /etc/os-release file not found."
    return 1
  fi
  local os_id os_version_id
  os_id=$(source /etc/os-release && echo "$ID")
  os_version_id=$(source /etc/os-release && echo "$VERSION_ID")
  if [ -z "$os_id" ] || [ -z "$os_version_id" ]; then
    echo "Error: Failed to extract ID or VERSION_ID from /etc/os-release."
    return 1
  fi
  export SYSTEM_ID="${os_id}-${os_version_id}"
}

cd $MICDN_HOME
rm -rf core/target
rm -rf asset/target
rm -rf maven/target
rm -rf blob/target

dub clean
dub build --build=release-nobounds --compiler=ldc2
mk_artifact "asset"
mk_artifact "blob"
mk_artifact "maven"

cd $MICDN_HOME
rm -rf target
mkdir -p target

system_version
cd ~/.m2/repository
zip  $MICDN_HOME/target/beangle-micdn-$version.$SYSTEM_ID.$arch.zip org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-asset/$version/beangle-micdn-asset-$version-$arch.bin.sha1 \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-blob/$version/beangle-micdn-blob-$version-$arch.bin.sha1 \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-$arch.bin \
org/beangle/micdn/beangle-micdn-maven/$version/beangle-micdn-maven-$version-$arch.bin.sha1

gpg -ab $MICDN_HOME/target/beangle-micdn-$version.$SYSTEM_ID.$arch.zip
