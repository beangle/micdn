module beangle.micdn.config;

import std.string;

class Config{
    ushort port;
    string uriContext;
    string fileBase;
    Profile[string] profiles;

    private Profile defaultProfile = new Profile( "*","micdn","--",false,false);
    this(ushort port,string uriContext,string fileBase){
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
}

import std.digest.sha;
import std.uni;
import std.datetime.systime;
class Profile{
    string path;
    string owner;
    string key;
    bool publicList;
    bool publicDownload;

    this(string path,string owner,string key,bool publicList,bool publicDownload){
        this.path=path;
        this.owner=owner;
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
unittest{
    auto profile= new Profile( "*","micdn","--",false,false);
    SysTime now=Clock.currTime();
    import core.time;
    now.fracSecs= msecs( 0);
    string uri="/netinstall.sh";
    string token=profile.genToken( uri,now);
    //import std.stdio;
    //writeln( "token="~token~"&t="~now.toISOString);
    assert(profile.verifyToken(uri,token,now));
}
