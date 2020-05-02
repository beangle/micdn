module beangle.micdn.config;

import std.string;

class Config{
    string host;
    ushort port;
    string uriContext;
    string fileBase;
    Profile[string] profiles;

    private Profile defaultProfile = new Profile( "","--",false,false);

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
        import std.xml;
        import std.conv;
        Config config;
        auto parser = new DocumentParser( content);
        auto root = parser.tag;
        string host = root.attr.get( "host","127.0.0.1");
        ushort port = root.attr.get( "port","8080").to!ushort;
        string uriContext = root.attr["context"];
        string fileBase = root.attr["base"];
        config = new Config( host,port,uriContext,fileBase);
        parser.onStartTag["profile"] = (ElementParser xml){
            string path = xml.tag.attr["path"];
            string key = xml.tag.attr["key"];
            string publicList = xml.tag.attr.get( "publicList","false");
            string publicDownload = xml.tag.attr.get( "publicDownload","false");
            config.profiles[path] = new Profile( path,key,publicList.to!bool,publicDownload.to!bool);
        };
        parser.parse();
        return config;
    }
}

import std.digest.sha;
import std.uni;
import std.datetime.systime;
class Profile{
    string path;
    string key;
    bool publicList;
    bool publicDownload;

    this(string path,string key,bool publicList,bool publicDownload){
        if (path.endsWith( "/")){
            this.path=path[0..$-1];
        }else {
            this.path=path;
        }
        this.key=key;
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
    string base;
    string path;
    SysTime updatedAt;

    public  string toJson(){
        import std.conv;
        return `{owner:"` ~ owner ~ `",base:"`~ base ~ `",name:"` ~ name ~`",size:` ~
        size.to!string ~ `,sha:"` ~ sha ~ `",mediaType:"` ~
        mediaType ~ `",path:"` ~ path ~ `",updatedAt:"` ~ updatedAt.toISOExtString ~ `"}`;
    }
}

unittest{
    auto profile= new Profile( "","--",false,false);
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
    <profile path="/group/test" key="--"/>
  </profiles>
</micdn>`;
    auto config = Config.parse( content);
    import std.stdio;
    assert(config.profiles.length ==1 );
    assert("/group/test" in config.profiles);
}

