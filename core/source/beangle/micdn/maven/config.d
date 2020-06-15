module beangle.micdn.maven.config;
import std.string;
import dxml.dom;
import std.conv;
import beangle.xml.reader;

class Config{
  /**artifact local repo*/
  string base;
  /**cache the artifacts*/
  bool cacheable;
  /**default remote repo*/
  string defaultRepo;
  /**candinates remote repos*/
  string[] remoteRepos=[];

  static auto CentralURL = "https://repo1.maven.org/maven2";
  static auto AliyunURL = "https://maven.aliyun.com/nexus/content/groups/public";

  this(string base,bool cacheable){
    this.base=base;
    this.cacheable=cacheable;
  }

  void addRemote(string remote){
    remoteRepos.length+=1;
    remoteRepos[$-1]=remote;
  }

  public static Config parse(string content){
    auto dom = parseDOM!simpleXML( content).children[0];
    auto attrs = getAttrs( dom);
    bool cacheable = attrs.get( "cacheable","true").to!bool;
    import std.path;
    string base = expandTilde( attrs.get( "base","~/.m2/repository"));
    Config config = new Config( base,cacheable);
    auto remotesEntries = children( dom,"remotes");
    if (!remotesEntries.empty){
      auto remoteEntries = children( remotesEntries.front,"remote");
      foreach (remoteEntry;remoteEntries){
        attrs = getAttrs( remoteEntry);
        if ("url" in attrs){
          config.addRemote( attrs["url"]);
        }else if ("alias" in attrs){
          switch ( attrs["alias"]){
            case "central": config.addRemote( CentralURL); break ;
            case "aliyun": config.addRemote( AliyunURL);break ;
            default: throw new Exception( "unknown named repo "~ attrs["alias"] );
          }
        }
      }
    }
    if (config.remoteRepos.length==0){
      config.addRemote( CentralURL);
    }
    config.defaultRepo= config.remoteRepos[$-1];
    return config;
  }
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

