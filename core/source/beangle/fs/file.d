module beangle.fs.file;

import std.stdio;
import std.file;
import std.zip;
import std.string;
import std.conv;
import vibe.core.log;

uint unzip(string zipfile,string base,string innerDir=null){
  string prefix=innerDir;
  if (null!=prefix && !prefix.endsWith( "/")){
    prefix ~="/";
  }
  uint count=0;
  if (exists( zipfile)){
    auto zip = new ZipArchive( read( zipfile));
    mkdirRecurse( base);
    foreach (name, am; zip.directory)   {
      if (null==prefix  || name.startsWith( prefix)){
        auto targetName=name;
        if (null!=prefix && name.startsWith( prefix)){
          targetName =targetName[prefix.length .. $];
        }
        if (targetName.endsWith( "/")){
          mkdirRecurse( base~"/"~targetName);
        } else if (targetName.length>0) {
          auto lastSlash=targetName.lastIndexOf( "/");
          if (lastSlash>0){
            mkdirRecurse( base~"/"~ targetName[0..lastSlash]);
          }
          zip.expand( am);
          assert(am.expandedData.length == am.expandedSize);
          std.file.write( base~"/"~targetName,am.expandedData);
          count +=1;
        }
      }
    }
  }
  return count;
}

uint refreshUnzip(string zipfile,string base,string innerDir=null){
  string prefix=innerDir;
  if (null!=prefix && !prefix.endsWith( "/")){
    prefix ~="/";
  }
  uint count=0;
  if (exists( zipfile)){
    auto zip = new ZipArchive( read( zipfile));
    mkdirRecurse( base);
    foreach (name, am; zip.directory)   {
      if (null==prefix  || name.startsWith( prefix)){
        auto targetName=name;
        if (null!=prefix && name.startsWith( prefix)){
          targetName =targetName[prefix.length .. $];
        }
        if (targetName.endsWith( "/")){
          mkdirRecurse( base~"/"~targetName);
        } else if (targetName.length>0) {
          auto lastSlash=targetName.lastIndexOf( "/");
          if (lastSlash>0){
            mkdirRecurse( base~"/"~ targetName[0..lastSlash]);
          }
          auto targetFile = base~"/"~targetName;
          bool  spawn=true;
          if (exists( targetFile) && getSize( targetFile) == am.expandedSize){
            spawn=false;
          }
          if (spawn){
            zip.expand( am);
            assert(am.expandedData.length == am.expandedSize);
            std.file.write( targetFile,am.expandedData);
          }
          count +=1;
        }
      }
    }
  }
  return count;
}

void setReadOnly(string dir){
  if (!exists( dir)){
    return ;
  }
  doSetReadOnly( dir);
}

private void doSetReadOnly(string dir){
  if (dir.isDir){
    dir.setAttributes( octal!555);
    foreach (d; dirEntries( dir, SpanMode.shallow)) {
      if (!d.isSymlink){
        if (d.isDir) {
          doSetReadOnly( d);
        }else {
          d.setAttributes( octal!444);
        }
      }
    }
  }else {
    dir.setAttributes( octal!444);
  }
}

void setWritable(string dir){
  if (!exists( dir)){
    return ;
  }
  doSetWritable( dir);
}

private void doSetWritable(string dir){
  if (dir.isDir){
    dir.setAttributes( dir.getAttributes | octal!700);
    foreach (d; dirEntries( dir, SpanMode.breadth)) {
      if (!d.isSymlink){
        if (d.isDir) {
          doSetWritable( d);
        }else {
          d.setAttributes( d.getAttributes | octal!200);
        }
      }
    }
  }else {
    dir.setAttributes( dir.getAttributes | octal!600);
  }
}

unittest{
  import std.file : read;
  import std.stdio;
  auto zipPath="/tmp/beangle-bundles-bui-0.2.1.jar";
  if (exists( zipPath)){
    auto base="/tmp/beangle-bundles-bui-0.2.1";
    unzip( zipPath,base,"META-INF/resources/bui");
    setReadOnly( base);
    setWritable( base);
    base.rmdirRecurse();
  }
}
