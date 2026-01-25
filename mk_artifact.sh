#!/bin/bash
set -e
PRGDIR=`dirname "$0"`
export MICDN_HOME=`cd "$PRGDIR" >/dev/null; pwd`
version=`grep "version " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
groupPath=~/.m2/repository/org/beangle/micdn

write_script(){
  scirptFile=$groupPath/$targetName/$version/micdn-$1-$version-$arch.sh
  echo -e '#!/bin/bash\nprgdir=$(cd "$(dirname "$0")" && pwd)' > $scirptFile
  echo exec \$prgdir/$targetName-$version-$arch.bin --as $1 \$@ >> $scirptFile
  more $scirptFile
  ls $scirptFile
  chmod +x $scirptFile
}

mk_artifact(){
  arch=`arch`
  targetName=`grep "targetName " -R dub.sdl |awk 'NR==1{gsub(/"/,"");print $2}'`
  rm -rf target/$targetName-$version-$arch.bin
  cp target/$targetName target/$targetName-$version-$arch.bin
  sha1sum target/$targetName-$version-$arch.bin|awk 'NR==1{gsub(/"/,"");print $1}' > target/$targetName-$version-$arch.bin.sha1

  mkdir -p $groupPath/$targetName/$version/
  rm -rf $groupPath/$targetName/$version/$targetName-$version-$arch.bin
  mv target/$targetName-$version-$arch.bin $groupPath/$targetName/$version/$targetName-$version-$arch.bin
  mv target/$targetName-$version-$arch.bin.sha1 $groupPath/$targetName/$version/$targetName-$version-$arch.bin.sha1
  write_script "maven"
  write_script "asset"
  write_script "blob"
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
mkdir -p target
rm -rf target/*

dub clean
dub build --build=release-nobounds --compiler=ldc2
mk_artifact

cd $MICDN_HOME

system_version
cd ~/.m2/repository
zip  $MICDN_HOME/target/micdn-$version.$SYSTEM_ID.$arch.zip org/beangle/micdn/micdn/$version/*

cd $MICDN_HOME
gpg -ab $MICDN_HOME/target/micdn-$version.$SYSTEM_ID.$arch.zip
