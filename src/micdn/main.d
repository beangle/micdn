module micdn.main;

void main(string[] args) {
  if (args.length < 5) {
    writeln("Usage: " ~ args[0] ~ " --as maven --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as asset --server path/to/server.xml --config path/to/config.xml");
    writeln("Usage: " ~ args[0] ~ " --as blob --server path/to/server.xml --config path/to/config.xml");
    return;
  }

  auto serverOptions = getServerOptions();

  string serverType;
  auto success = readOption!string("as", &serverType, "Please specify --as params[maven|asset|blob]");
  if (!success) {
    writeln("Please specify --as params[maven|asset|blob]");
    return;
  } else {
    switch (serverType) {
    case "maven":
      import micdn.maven.server : mavenStart;

      mavenStart(getHome("~/.m2/repository"), serverOptions, getConfigFile(home, "/maven.xml", true));
    case "asset":
      import micdn.asset.server : assetStart;

      assetStart(getHome(), serverOptions, getConfigFile(home, "/asset.xml", true));
    case "blob":
      import micdn.blob.server : blobStart;

      blobStart(getHome(), serverOptions, getConfigFile(home, "/blob.xml", true));
    default:
      writeln("Unsupported --as params[" ~ serverType ~ "],only support[maven|asset|blob]");
      return;
    }
  }

}
