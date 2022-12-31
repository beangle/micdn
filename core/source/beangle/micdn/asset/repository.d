module beangle.micdn.asset.repository;

import beangle.micdn.asset.config;
import beangle.fs.file;
import std.file;
import std.string;
import std.path;
import std.string;
import vibe.core.log;

class Repository{
  const string base;

  this(string base){
    this.base=base;
  }

  string[] get(string uri){
    if (uri.indexOf( "..") > -1 )return null;
    auto files= resolve( uri);
    for (int i=0;i<files.length;i++){
      auto location=base~files[i];
      if (exists( location )) {
        files[i]= location;
      } else {
        logWarn( "Cannot find %s",location);
        return null;
      }
    }
    return files;
  }

  static string [] resolve(string uri){
    auto commaIdx=uri.indexOf( ',');
    if (commaIdx > 0 ){
      auto lastDotIdx=lastIndexOf( uri,'.');
      auto extension = uri[lastDotIdx ..$];
      string path = uri[0..commaIdx];
      auto lastSlashIdx=lastIndexOf( path,'/');
      path = path[0..lastSlashIdx+1];
      string[] names = split( uri[(lastSlashIdx+1) .. lastDotIdx],',');
      for (int i=0;i<names.length;i++) {
        names[i]=path ~ names[i] ~ extension;
      }
      return names;
    }else {
      return [ uri];
    }
  }

  static Repository build(Config config){
    if (exists( config.base)){
      setWritable( config.base);
      //rmdirRecurse( config.base);
    }
    mkdirRecurse( config.base);
    auto repo = config.repo;
    logInfo( "Building repository at %s", config.base);
    foreach (c;config.contexts){
      foreach (p;c.providers){
        if (DirProvider dp = cast(DirProvider) p){
          if (exists( dp.location)){
            if (exists( config.base ~ c.base)){
              remove( config.base ~ c.base);
            }
            logInfo("Linking "~ dp.location ~" to " ~ config.base~c.base);
            symlink( dp.location,config.base ~ c.base);
          }else {
            logWarn( "Cannot link " ~ dp.location ~" to " ~ config.base~c.base);
          }
        }else if (GavJarProvider gap = cast(GavJarProvider) p){
          string local= repo.localFile( gap.gav);
          string location=gap.location;
          if (null == location ){
            if (gap.gav.startsWith( "org.webjars")) {
              location = "META-INF/resources/webjars";
            }else {
              location = "META-INF/resources";
            }
          }
          location ~= c.base;
          if (exists( local)){
            mount( config,local,c.base,location);
          }else if(!local.endsWith( "SNAPSHOT.jar")) {
            string remote = repo.remoteUrl( gap.gav);
            mkdirRecurse( dirName( local));
            import vibe.inet.urltransfer;
            logInfo( "Downloading %s", remote);
            try{
              download( remote,local);
              mount( config,local,c.base,location);
            }catch(Exception e){
              logWarn( "Download failure %s",remote);
            }
          }else{
            logWarn( "Cannot resolve %s,ignore it.",gap.gav);
          }
        } else if (ZipProvider zp = cast(ZipProvider ) p ){
          mount( config,zp.file,c.base,zp.location);
        }else {
          //throw new R
        }
      }
    }
    setReadOnly( config.base);
    return new Repository( config.base);
  }

  private static void  mount(Config config,string zipfile,string base,string location){
    logInfo( "Mounting %s",zipfile);
    auto count=refreshUnzip( zipfile,config.base~base,location);
    if (count==0){
      logWarn( "Cannot find %s in %s",location,zipfile);
    }
  }
}

unittest{
  auto uri="/a/b,c.js";
  auto paths=Repository.resolve( uri);
  assert(paths.length==2);
  assert(paths[1] =="/a/c.js");

  uri="/a/b,c1/c.min,c2/c.min.js";
  paths=Repository.resolve( uri);
  assert(paths.length==3);
  assert(paths[1] =="/a/c1/c.min.js");
  assert(paths[2] =="/a/c2/c.min.js");
}

unittest{
  auto content=`<?xml version="1.0" encoding="UTF-8"?>
<assets>
  <repository remote="https://repo1.maven.org/maven2"/>
  <contexts>
    <context base="/urp/">
       <dir location="~/.openurp/static"/>
    </context>
    <context base="/my97/">
       <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </context>

    <context base="/bui/">
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.4"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.0"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.1"/>
    </context>
  </contexts>
</assets>`;
  auto config = Config.parse("~/tmp", content);
  assert(config.base==expandTilde("~/tmp/static"));
  //auto repo=Repository.build( config);

}
