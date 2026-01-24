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
import std.typecons;

auto readConfig(string defaultHome, string defaultConfigFileName) {
  string home;
  string config;
  string remoteDir;
  auto hasHome = readOption!string("home", &home, "specify home params");
  auto hasConfig = readOption!string("config", &config, "specify config params");
  auto hasRemote = readOption!string("remote", &remoteDir, "specify remote params");

  if (hasHome && hasConfig) {
    return tuple(home, config);
  } else if (hasHome) {
    if (home.endsWith("/"))
      home = home[0 .. $ - 1];
    home = expandTilde(home);
    config = expandTilde(home ~ "/" ~ defaultConfigFileName);
    if (hasRemote) {
      auto newxml = config ~ ".new";
      auto remoteUrl = remoteDir ~ "/" ~ defaultConfigFileName;
      if (curlDownload(remoteUrl, newxml)) {
        logInfo("Downloaded %s", remoteUrl);
        rename(newxml, config);
      }
    }
    return tuple(home, config);
  } else if (hasConfig) {
    home = (std.file.exists(config)) ? std.path.dirName(config) : defaultHome;
    return tuple(defaultHome, config);
  } else {
    return tuple(defaultHome, defaultHome ~ "/" ~ defaultConfigFileName);
  }
}

import std.file;

ServerOptions getServerOptions(string serverType) {
  string serverFile;
  auto success = readOption!string("server", &serverFile, "specify server params");
  if (success) {
    if (exists(serverFile)) {
      return ServerOptions.parse(cast(string) read(serverFile));
    } else {
      throw new Exception(serverFile ~ " is not exists!");
    }
  } else {
    auto defaultConfig = `<?xml version="1.0" encoding="UTF-8"?><Server ips="127.0.0.1" port="8080">` ~
      `<Context path="/` ~ serverType ~ `"/></Server>`;
    return ServerOptions.parse(defaultConfig);
  }
}
