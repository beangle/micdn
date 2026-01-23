module micdn.web.server;

import dxml.dom;
import std.algorithm;
import std.file;
import std.path;
import vibe.core.log;
import micdn.web.file;

class ServerOptions {
  string[] ips;
  ushort port;
  string contextPath;

  this(string[] ips, ushort port, string contextPath) {
    this.ips = ips;
    this.port = port;
    this.contextPath = contextPath;
  }

  public static ServerOptions parse(string content) {
    import std.conv;
    import micdn.xml.reader;

    auto dom = parseDOM!simpleXML(content).children[0];
    auto attrs = getAttrs(dom);
    string hosts;
    if ("ips" in attrs) {
      hosts = attrs.get("ips", "127.0.0.1");
    } else {
      hosts = attrs.get("hosts", "127.0.0.1");
    }
    ushort port = attrs.get("port", "8080").to!ushort;
    auto contextEntries = children(dom, "Context");
    if (contextEntries.empty) {
      throw new Exception("Context element is needed in server.xml.");
    }
    auto contextAttrs = getAttrs(contextEntries.front);
    import std.array;

    return new ServerOptions(split(hosts, ","), port, contextAttrs["path"]);
  }

  @property public string listenAddr() const {
    import std.conv;

    return this.ips[0] ~ ":" ~ port.to!string;
  }

}

unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<Server ips="192.168.31.244" port="8081">
  <Context path="/blob" />
</Server>`;
  auto server = ServerOptions.parse(content);
  import std.stdio;

  assert(server.ips.length == 1);

  string test = "~/ems/micdn/asset.xml";
  assert(dirName(test) == "~/ems/micdn");
}

import vibe.core.args;

string getHome(string defaultPath = "~") {
  string home;
  auto success = readOption!string("home", &home, "specify home params");
  if (success) {
    if (home.endsWith("/"))
      home = home[0 .. $ - 1];
    return expandTilde(home);
  } else {
    string serverxml;
    success = readOption!string("config", &serverxml, "specify config params");
    if (success) {
      return (std.file.exists(serverxml)) ? std.path.dirName(serverxml) : defaultPath;
    } else {
      return defaultPath;
    }
  }
}

string getConfigFile(string home, string defaultPath, bool checkRemote) {
  string serverxml;
  auto success = readOption!string("config", &serverxml, "specify config params");
  if (!success) {
    serverxml = expandTilde(home ~ defaultPath);
    if (checkRemote) {
      string remoteUrl;
      auto hasRemote = readOption!string("remote", &remoteUrl, "specify remote params");
      if (hasRemote) {
        auto newxml = serverxml ~ ".new";
        if (curlDownload(remoteUrl ~ defaultPath, newxml)) {
          logInfo("Downloaded %s", remoteUrl ~ defaultPath);
          rename(newxml, serverxml);
        }
      }
    }
  }
  return serverxml;
}

import std.file;

string readXml(string xmlfile) {
  auto fullPath = expandTilde(xmlfile);
  if (exists(fullPath)) {
    return cast(string) read(fullPath);
  } else {
    throw new Exception(xmlfile ~ " is not exists!");
  }
}

ServerOptions getServerOptions() {
  string serverxml;
  auto success = readOption!string("server", &serverxml, "specify server params");
  if (success) {
    return parseServerOptions(expandTilde(serverxml));
  } else {
    throw new Exception("Missing server params");
  }
}

ServerOptions parseServerOptions(string serverxml) {
  if (exists(serverxml)) {
    return ServerOptions.parse(cast(string) read(serverxml));
  } else {
    throw new Exception(serverxml ~ " is not exists!");
  }
}
