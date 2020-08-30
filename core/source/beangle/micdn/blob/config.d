module beangle.micdn.blob.config;

import std.string;
import dxml.dom;
import std.stdio;
import std.conv;
import beangle.xml.reader;

class Config{
  immutable string hostname;
  /**file base store blobs*/
  immutable string base;
  /**enable dir list*/
  immutable bool publicList;
  /**upload file limit*/
  ulong maxSize=10*1024*1024; //default 10m
  /**url profile for management*/
  Profile[string] profiles;
  /**every key for profile*/
  string[string] keys;
  /**store datasource properties*/
  string[string] dataSourceProps;

  private Profile defaultProfile = new Profile( 0,"",null,false,false);

  this(string hostname,string base,bool publicList){
    this.hostname=hostname;
    this.base=base;
    this.publicList=publicList;
  }

  Profile getProfile(string path){
    foreach (k,v;profiles){
      if (path.startsWith( k)){
        return v;
      }
    }
    return defaultProfile;
  }

  public static Config parse(string content){
    Config config;
    auto dom = parseDOM!simpleXML( content).children[0];
    auto attrs = getAttrs( dom);
    string sizeLimit=attrs.get( "maxSize","50M");
    import std.path;
    string base=expandTilde( attrs["base"]);
    string hostname=attrs.get( "hostname","localhost");
    bool publicList = attrs.get( "publicList","false").to!bool;
    config = new Config( hostname, base,publicList);
    config.maxSize=parseSize( sizeLimit);
    auto usersEntry = children( dom,"users");
    if (!usersEntry.empty){
      auto userEntries=children( usersEntry.front,"user");
      foreach (u;userEntries){
        attrs= getAttrs( u);
        config.keys[attrs["name"]]= attrs["key"];
      }
    }
    auto profilesEntry= children( dom,"profiles");
    if (!profilesEntry.empty){
      auto profileEntries=children( profilesEntry.front,"profile");
      foreach (p;profileEntries){
        attrs= getAttrs( p);
        int id = attrs["id"].to!int;
        string path =attrs["base"];
        string users = attrs.get( "users","");
        string[string] profileKeys;
        if (!users.empty){
          foreach (u;users.split( ",")){
            profileKeys[u]=config.keys[u];
          }
        }
        bool namedBySha = attrs.get( "namedBySha","false").to!bool;
        bool publicDownload = attrs.get( "publicDownload","false").to!bool;
        config.profiles[path] = new Profile( id,path,profileKeys,namedBySha,publicDownload);
      }
    }
    auto dataSource= children( dom,"dataSource").front;
    foreach (p;dataSource.children){
      config.dataSourceProps[p.name]=p.children[0].text;
    }
    return config;
  }

  public static ulong parseSize(string size){
    string s=size.toLower;
    if (s.endsWith( "m")){
      return s[0..$-1].to!ulong*1024*1024;
    }else if (s.endsWith( "g")){
      return s[0..$-1].to!ulong*1024*1024*1024;
    }else {
      return s[0..$-1].to!ulong;
    }
  }
}

import std.digest.sha;
import std.uni;
import std.datetime.systime;
class Profile{
  immutable int id;
  /**profile path prefix*/
  immutable string base;
  /**which user/key could write this profile*/
  immutable string[string] keys;
  /**should name file by sha*/
  immutable bool namedBySha;
  /**could download file publicly*/
  immutable bool publicDownload;

  this(int id,string base,string[string] keys,bool namedBySha,bool publicDownload){
    this.id=id;
    if (base.endsWith( "/")){
      this.base=base[0..$-1];
    }else {
      this.base=base;
    }
    this.keys=to!(immutable(string[string]))( keys);
    this.namedBySha=namedBySha;
    this.publicDownload=publicDownload;
  }

  string genToken(string path,string user,string key,SysTime timestamp)   {
    string content = path ~ user ~ key ~ timestamp.toISOString;
    return toHexString( sha1Of( content)).toLower;
  }

  bool verifyToken(string path,string user,string key,string token,SysTime timestamp)   {
    SysTime today = Clock.currTime();
    import core.time;
    auto duration = abs( today - timestamp);
    if (duration > dur!"minutes"( 15)){
      return false;
    }else {
      string content = path ~ user ~ key ~ timestamp.toISOString;
      return toHexString( sha1Of( content)).toLower == token;
    }
  }
}

class BlobMeta{
  string owner;
  string name;
  ulong fileSize;
  string sha;
  string mediaType;
  int profileId;
  string filePath;
  SysTime updatedAt;

  string toJson(){
    return `{owner:"` ~ owner ~ `",profileId:`~ profileId.to!string ~ `,name:"` ~ name ~`",fileSize:` ~
    fileSize.to!string ~ `,sha:"` ~ sha ~ `",mediaType:"` ~
    mediaType ~ `",filePath:"` ~ filePath ~ `",updatedAt:"` ~ updatedAt.toISOExtString ~ `"}`;
  }
}

unittest{
  string[string] keys;
  keys["default"] = "--";
  auto profile= new Profile( 0, "",keys,false,false);
  SysTime now=Clock.currTime();
  import core.time;
  now.fracSecs= msecs( 0);
  string uri="/netinstall.sh";
  string token=profile.genToken( uri,"default","--",now);
  //import std.stdio;
  //writeln( "token="~token~"&t="~now.toISOString);
  assert(profile.verifyToken( uri,"default","--",token,now));
}

unittest{
  auto content=`<?xml version="1.0"?>
<blob port="9080" context="/micdn" base="/home/chaostone/tmp">
  <users>
    <user name="default" key="--"/>
  </users>
  <profiles>
    <profile id="0" base="/group/test" users="default"/>
  </profiles>
  <dataSource>
    <serverName>localhost</serverName>
    <databaseName>platform</databaseName>
    <user>postgres</user>
    <password>1</password>
    <tableName>public.blob_metas</tableName>
  </dataSource>
</blob>`;
  auto config = Config.parse( content);
  import std.stdio;
  assert(config.profiles.length ==1 );
  assert("/group/test" in config.profiles);
  assert("databaseName" in config.dataSourceProps);
  assert(10L*1024*1024*1024 == config.parseSize( "10g"));
}

