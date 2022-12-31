module beangle.web.server;

import dxml.dom;
import std.algorithm;
import std.file;
import std.path;
import vibe.core.log;

class Server{
  string[] ips;
  ushort port;
  string contextPath;

  this(string[] ips,ushort port,string contextPath){
    this.ips=ips;
    this.port=port;
    this.contextPath=contextPath;
  }

  public static Server parse(string content){
    import std.conv;
    Server server;
    auto dom = parseDOM!simpleXML( content).children[0];
    auto attrs = getAttrs( dom);
    string hosts ;
    if ("ips" in attrs){
      hosts= attrs.get( "ips","127.0.0.1");
    }else {
      hosts= attrs.get( "hosts","127.0.0.1");
    }
    ushort port = attrs.get( "port","8080").to!ushort;
    auto contextEntries= children( dom,"Context");
    if (contextEntries.empty){
      throw new Exception( "Context element is needed in server.xml.");
    }
    auto contextAttrs = getAttrs( contextEntries.front);
    import std.array;
    return new Server( split( hosts,","),port,contextAttrs["path"]);
  }
  @property
  public string listenAddr(){
    import std.conv;
    return this.ips[0] ~":" ~ port.to!string;
  }
  private static auto getAttrs(T)(ref DOMEntity!T dom){
    string[string] a;
    foreach (at;dom.attributes){
      a[at.name]=at.value;
    }
    return a;
  }
  private static auto children(T)(ref DOMEntity!T dom,string path){
    import std.algorithm;
    return dom.children.filter!(c => c.name==path);
  }

}

unittest{
  auto content=`<?xml version="1.0" encoding="UTF-8"?>
<Server ips="192.168.31.244" port="8081">
  <Context path="/blob" />
</Server>`;
  auto server = Server.parse( content);
  import std.stdio;
  assert(server.ips.length == 1 );

  string test = "~/ems/micdn/asset.xml";
  assert(dirName(test) == "~/ems/micdn");
}

import vibe.core.args;

string getHome(){
  string home;
  auto success = readOption!string( "home",&home,"specify home params");
  if (success){
    if (home.endsWith( "/")) home = home[0..$-1];
    return home;
  }else {
    string serverxml;
    success = readOption!string( "config",&serverxml,"specify config params");
    if(success){
      return (std.file.exists(serverxml))?std.path.dirName(serverxml) : "~";
    }else{
      return "~";
    }
  }
}

string getConfigFile(string home,string defaultPath,bool checkRemote){
  string serverxml;
  auto success = readOption!string( "config",&serverxml,"specify config params");
  if(!success){
    serverxml = expandTilde(home ~ defaultPath);
    if(checkRemote){
      string remoteUrl;
      auto hasRemote = readOption!string( "remote",&remoteUrl,"specify remote params");
      if(hasRemote){
        auto newxml = serverxml ~ ".new";
        try{
          logInfo( "Downloading %s",remoteUrl ~ defaultPath);
          import vibe.inet.urltransfer;
          download(remoteUrl ~ defaultPath, newxml);
          if (exists(newxml)) rename(newxml, serverxml);
        }catch(Exception e){
          logWarn( "Cannot fetch %s",remoteUrl ~ defaultPath ~ " for " ~ e.toString());
        }
      }
    }
  }
  return serverxml;
}

import std.file;
string readXml(string xmlfile){
  auto fullPath = expandTilde(xmlfile);
  if (exists(fullPath)){
    return cast(string) read(fullPath);
  }else{
    throw new Exception( xmlfile ~ " is not exists!");
  }
}

Server getServer(){
  string serverxml;
  auto success = readOption!string( "server",&serverxml,"specify server params");
  if (success){
    return parseServer( expandTilde(serverxml));
  }else {
    throw new Exception( "Missing server params");
  }
}

Server parseServer(string serverxml){
  if (exists( serverxml)){
    return Server.parse( cast(string) read( serverxml));
  }else {
    throw new Exception( serverxml ~ " is not exists!");
  }
}

