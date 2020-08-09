module beangle.micdn.maven.config;
import std.string;
import dxml.dom;
import std.conv;
import beangle.xml.reader;

class Config{
  /**artifact local repo*/
  immutable string base;
  /**cache the artifacts*/
  immutable bool cacheable;
  /**enable dir list*/
  immutable bool publicList;
  /**candinates remote repos*/
  immutable string[] remoteRepos=[];
  /**default remote repo*/
  immutable string defaultRepo;

  static auto CentralURL = "https://repo1.maven.org/maven2";
  static auto AliyunURL = "https://maven.aliyun.com/nexus/content/groups/public";

  this(string base,bool cacheable,bool publicList,string[] remoteRepos){
    this.base=base;
    this.cacheable=cacheable;
    this.publicList=publicList;
    this.remoteRepos=to!(immutable(string[]))(remoteRepos);
    this.defaultRepo=remoteRepos[$-1];
  }

  public static Config parse(string content){
    auto dom = parseDOM!simpleXML( content).children[0];
    auto attrs = getAttrs( dom);
    bool cacheable = attrs.get( "cacheable","true").to!bool;
    bool publicList = attrs.get( "publicList","false").to!bool;
    import std.path;
    string base = expandTilde( attrs.get( "base","~/.m2/repository"));
    string[] remoteRepos=[];
    auto remotesEntries = children( dom,"remotes");
    if (!remotesEntries.empty){
      auto remoteEntries = children( remotesEntries.front,"remote");
      foreach (remoteEntry;remoteEntries){
        attrs = getAttrs( remoteEntry);
        if ("url" in attrs){
          remoteRepos.add( attrs["url"]);
        }else if ("alias" in attrs){
          switch ( attrs["alias"]){
            case "central": remoteRepos.add( CentralURL); break ;
            case "aliyun":remoteRepos.add( AliyunURL);break ;
            default: throw new Exception( "unknown named repo "~ attrs["alias"] );
          }
        }
      }
    }
    if (remoteRepos.length==0){
      remoteRepos.add( CentralURL);
    }
    return new Config( base,cacheable,publicList,remoteRepos);
  }

}

void add(string[] remotes,string remote){
  remotes.length+=1;
  remotes[$-1]=remote;
}

unittest{
  auto content=`<?xml version="1.0" encoding="UTF-8"?>
<maven cacheable="true" >
  <remotes>
    <remote url="https://maven.aliyun.com/nexus/content/groups/public"/>
    <remote alias="central"/>
  </remotes>
</maven>`;

  auto config = Config.parse( content);
  assert( config.remoteRepos.length==2);
  assert( config.remoteRepos[1] == Config.CentralURL);
}

