module beangle.micdn.blob.repository;

import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.conv;
import beangle.micdn.blob.db;
import beangle.micdn.blob.config;

class Repository{
  string base;
  MetaDao metaDao;
  bool[string] images;

  this(string b,MetaDao metaDao){
    this.base=b;
    this.metaDao=metaDao;
    images[".jpg"]=true;
    images[".png"]=true;
    images[".gif"]=true;
  }

  int check(string path){
    if (path.indexOf( "..") > -1 ) return 0;
    if (exists( base ~ path)){
      if (isDir( base ~ path)){
        return 1;
      }else {
        return 2;
      }
    }else {
      return 0;
    }
  }

  public string getRealname(Profile profile,string path){
    if (metaDao !is null){
      return metaDao.getFilename( profile,path);
    }else {
      return "";
    }
  }

  public BlobMeta create(Profile profile,string tmpfile,string filename,string dir,string owner,string mediaType){
    auto meta= new BlobMeta();
    import std.digest,std.digest.sha;
    auto tmp= File( tmpfile);
    auto shaHex = toHexString!(LetterCase.lower)( digest!SHA1( tmp.byChunk( 4096 * 1024))).idup;
    meta.profileId=profile.id;
    meta.owner=owner;
    meta.name=filename;
    meta.fileSize=tmp.size();
    meta.mediaType=mediaType;
    meta.sha=shaHex;
    import std.datetime.systime;
    meta.updatedAt=Clock.currTime();
    import std.path;
    auto filePath ="";
    if (profile.namedBySha){
      auto ext= extension( meta.name);
      if (dir.endsWith( "/")){
        filePath = dir  ~ shaHex ~ ext;
      }else {
        filePath = dir ~ "/" ~ shaHex ~ ext;
      }
    }else {
      if (dir.endsWith( "/")){
        filePath = dir ~ meta.name;
      }else {
        filePath = dir ~ "/" ~ meta.name;
      }
    }
    meta.filePath=filePath[profile.base.length .. $];
    mkdirRecurse( dirName( this.base ~ profile.base ~ meta.filePath));
    copy( tmpfile, this.base ~ profile.base ~ meta.filePath);
    if (metaDao !is null){
      metaDao.remove( profile,meta.filePath);
      metaDao.create( profile,meta);
    }
    return meta;
  }

  public bool remove(Profile profile,string path){
    if (std.file.exists( this.base ~ path)){
      std.file.remove( this.base ~ path );
      if ( metaDao !is null){
        metaDao.remove( profile,path[profile.base.length..$]);
      }
      return true;
    }else {
      return false;
    }
  }

}
