module beangle.micdn.config;

import std.string;
import dxml.dom;
import std.stdio;
class Config{
    string host;
    ushort port;
    string uriContext;
    string fileBase;
    Profile[string] profiles;

    string[string] dataSourceProps;

    private Profile defaultProfile = new Profile( 0,"","--",false,false,false);

    this(string host,ushort port,string uriContext,string fileBase){
        this.host=host;
        this.port=port;
        this.uriContext=uriContext;
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

    @property
    public string listenAddr(){
        import std.conv;
        return this.host ~":" ~ port.to!string;
    }

    public static Config parse(string content){
        import std.conv;
        Config config;
        auto dom = parseDOM!simpleXML( content).children[0];
        auto attrs = getAttrs( dom);
        string host = attrs.get( "host","127.0.0.1");
        ushort port = attrs.get( "port","8080").to!ushort;
        string uriContext = attrs["context"];
        string fileBase = attrs["base"];
        config = new Config( host,port,uriContext,fileBase);
        auto profiles=children( children( dom,"profiles").front,"profile");
        foreach (p;profiles){
            attrs= getAttrs( p);
            int id = attrs["id"].to!int;
            string path =attrs["path"];
            string key =attrs["key"];
            bool namedBySha = attrs.get( "namedBySha","false").to!bool;
            bool publicList = attrs.get( "publicList","false").to!bool;
            bool publicDownload = attrs.get( "publicDownload","false").to!bool;
            config.profiles[path] = new Profile( id,path,key,namedBySha,publicList,publicDownload);
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
}

import std.digest.sha;
import std.uni;
import std.datetime.systime;
class Profile{
    int id;
    string path;
    string key;
    bool namedBySha;
    bool publicList;
    bool publicDownload;

    this(int id,string path,string key,bool namedBySha,bool publicList,bool publicDownload){
        this.id=id;
        if (path.endsWith( "/")){
            this.path=path[0..$-1];
        }else {
            this.path=path;
        }
        this.key=key;
        this.namedBySha=namedBySha;
        this.publicList=publicList;
        this.publicDownload=publicDownload;
    }

    string genToken(string path,SysTime timestamp){
        string content = path ~ this.key ~ timestamp.toISOString;
        return toHexString( sha1Of( content)).toLower;
    }

    bool verifyToken(string path,string token,SysTime timestamp){
        SysTime today = Clock.currTime();
        import core.time;
        auto duration = abs( today - timestamp);
        if (duration > dur!"minutes"( 15)){
            return false;
        }else {
            string content = path ~ this.key ~ timestamp.toISOString;
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

    public  string toJson(){
        import std.conv;
        return `{owner:"` ~ owner ~ `",profileId:`~ profileId.to!string ~ `,name:"` ~ name ~`",size:` ~
        size.to!string ~ `,sha:"` ~ sha ~ `",mediaType:"` ~
        mediaType ~ `",path:"` ~ path ~ `",updatedAt:"` ~ updatedAt.toISOExtString ~ `"}`;
    }
}

unittest{
    auto profile= new Profile( 0, "","--",false,false,false);
    SysTime now=Clock.currTime();
    import core.time;
    now.fracSecs= msecs( 0);
    string uri="/netinstall.sh";
    string token=profile.genToken( uri,now);
    //import std.stdio;
    //writeln( "token="~token~"&t="~now.toISOString);
    assert(profile.verifyToken( uri,token,now));
}

unittest{
    auto content=`<?xml version="1.0"?>
<micdn port="9080" context="/micdn" base="/home/chaostone/tmp">
  <profiles>
    <profile id="0" path="/group/test" key="--"/>
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
}

