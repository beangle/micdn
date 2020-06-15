module beangle.micdn.blob.config;

import std.string;
import dxml.dom;
import std.stdio;
import std.conv;

class Config{
  string fileBase;
  ulong maxSize=10*1024*1024; //default 10m
  Profile[string] profiles;
  string[string] keys;
  string[string] dataSourceProps;

  private Profile defaultProfile = new Profile( 0,"",null,false,false,false);

  this(string fileBase){
    this.fileBase=fileBase;
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
    string fileBase = attrs["base"];
    string sizeLimit=attrs.get( "maxSize","50M");
    config = new Config( fileBase);
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
        string path =attrs["path"];
        string users = attrs.get( "users","");
        string[string] profileKeys;
        if (!users.empty){
          foreach (u;users.split( ",")){
            profileKeys[u]=config.keys[u];
          }
        }
        bool namedBySha = attrs.get( "namedBySha","false").to!bool;
        bool publicList = attrs.get( "publicList","false").to!bool;
        bool publicDownload = attrs.get( "publicDownload","false").to!bool;
        config.profiles[path] = new Profile( id,path,profileKeys,namedBySha,publicList,publicDownload);
      }
    }
    auto dataSource= children( dom,"dataSource").front;
    foreach (p;dataSource.children){
      config.dataSourceProps[p.name]=p.children[0].text;
    }
    return config;
  }

  private static auto children(T)(ref DOMEntity!T dom,string path){
    import std.algorithm;
    return dom.children.filter!(c => c.name==path);
  }

  private static auto getAttrs(T)(ref DOMEntity!T dom){
    string[string] a;
    foreach (at;dom.attributes){
      a[at.name]=at.value;
    }
    return a;
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
  int id;
  string path;
  string[string] keys;
  bool namedBySha;
  bool publicList;
  bool publicDownload;

  this(int id,string path,string[string] keys,bool namedBySha,bool publicList,bool publicDownload){
    this.id=id;
    if (path.endsWith( "/")){
      this.path=path[0..$-1];
    }else {
      this.path=path;
    }
    this.keys=keys;
    this.namedBySha=namedBySha;
    this.publicList=publicList;
    this.publicDownload=publicDownload;
  }

  string genToken(string path,string user,string key,SysTime timestamp){
    string content = path ~ user ~ key ~ timestamp.toISOString;
    return toHexString( sha1Of( content)).toLower;
  }

  bool verifyToken(string path,string user,string key,string token,SysTime timestamp){
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
  ulong size;
  string sha;
  string mediaType;
  int profileId;
  string path;
  SysTime updatedAt;

   string toJson(){
    return `{owner:"` ~ owner ~ `",profileId:`~ profileId.to!string ~ `,name:"` ~ name ~`",size:` ~
    size.to!string ~ `,sha:"` ~ sha ~ `",mediaType:"` ~
    mediaType ~ `",path:"` ~ path ~ `",updatedAt:"` ~ updatedAt.toISOExtString ~ `"}`;
  }
}

unittest{
  string[string] keys;
  keys["default"] = "--";
  auto profile= new Profile( 0, "",keys,false,false,false);
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
<micdn port="9080" context="/micdn" base="/home/chaostone/tmp">
  <users>
    <user name="default" key="--"/>
  </users>
  <profiles>
    <profile id="0" path="/group/test" users="default"/>
  </profiles>
  <dataSource>
    <serverName>localhost</serverName>
    <databaseName>platform</databaseName>
    <user>postgres</user>
    <password>1</password>
    <tableName>public.blob_metas</tableName>
  </dataSource>
</micdn>`;
  auto config = Config.parse( content);
  import std.stdio;
  assert(config.profiles.length ==1 );
  assert("/group/test" in config.profiles);
  assert("databaseName" in config.dataSourceProps);
  assert(10L*1024*1024*1024 == config.parseSize( "10g"));
}

