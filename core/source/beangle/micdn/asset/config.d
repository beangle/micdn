module beangle.micdn.asset.config;

import std.file;
import std.algorithm;
import std.string;
import dxml.dom;
import beangle.xml.reader;
import std.array : appender;

struct Repo{
  string remote;
  string local;
  private string path(string gav){
    auto parts= split( gav,":");
    assert(parts.length==3);
    parts[0]= replace( parts[0],".","/");
    return "/"~parts[0]~"/"~parts[1]~"/"~parts[2]~"/"~parts[1]~"-"~parts[2]~".jar";
  }
  string remoteUrl(string gav){
    return remote ~ path( gav);
  }
  string localFile(string gav){
    return local ~ path( gav);
  }
}

class Config{
  Repo repo;
  string base;
  Context[string] contexts;

  this(string base, Repo repo){
    this.base=base;
    this.repo=repo;
  }

  void addContext(Context context){
    contexts[context.base]=context;
  }

  public static Config parse(string content){
    auto dom = parseDOM!simpleXML( content).children[0];
    auto attrs = getAttrs( dom);
    string base = attrs.get( "base","~/.beangle/assets");
    auto repoEntry = children( dom,"repository");
    auto remote="https://repo1.maven.org/maven2";
    auto local="~/.m2/repository";
    if (!repoEntry.empty){
      attrs = getAttrs( repoEntry.front);
      if ("remote" in attrs){
        remote =attrs["remote"];
      }
      if ("local" in attrs){
        local =attrs["local"];
      }
    }
    import std.path;
    base=expandTilde(base);

    Config config = new Config( base,Repo( remote,expandTilde( local)));
    auto contextsEntry= children( dom,"contexts");
    if (!contextsEntry.empty){
      auto contextEntries=children( contextsEntry.front,"context");
      foreach (c;contextEntries){
        auto context= new Context(  getAttrs( c)["base"]);
        auto jars=children( c,"jar");
        foreach (jar;jars){
          attrs = getAttrs( jar);
          string gav = attrs["gav"];
          string location = null;
          if ("location" in attrs){
            location =attrs["location"];
          }
          context.addProvider( new GavJarProvider( gav,location));
        }
        auto dirs=children( c,"dir");
        foreach (dir;dirs){
          attrs = getAttrs( dir);
          string location = expandTilde( attrs["location"]);
          context.addProvider( new DirProvider( location));
        }
        auto zips=children( c,"zip");
        foreach (zip;zips){
          attrs= getAttrs( zip);
          string file = attrs["file"];
          string location = attrs["location"];
          context.addProvider( new ZipProvider( file,location));
        }
        config.addContext( context);
      }
    }
    return config;
  }

  string toXml(){
    auto app = appender!string();
    app.put( `<?xml version="1.0" encoding="UTF-8"?>`);
    app.put( "\n");
    app.put( "<assets base=\"" ~ base ~ "\">\n");
    app.put( "  <repository remote=\"" ~ repo.remote ~ "\" local=\""~ repo.local~"\" />\n");
    app.put( "  <contexts>\n");
    foreach (c;contexts){
      app.put( c.toXml( "    "));
      app.put( "\n");
    }
    app.put( "  </contexts>\n");
    app.put( "</assets>\n");
    return app.data;
  }
}

class Context{
  string base;
  Provider[] providers=new Provider[0];
  this(string base){
    if (base.endsWith( "/")){
      this.base=base[0..$-1];
    }else {
      this.base=base;
    }
  }
  void addProvider(Provider p){
    providers.length+=1;
    providers[providers.length-1]=p;
  }
  string toXml(string indent){
    auto app = appender!string();
    app.put( indent ~ "<context base=\"" ~ base ~"\">\n");
    foreach (p;providers){
      app.put( p.toXml( indent ~ "  "));
      app.put( "\n");
    }
    app.put( indent~ "</context>");
    return app.data;
  }
}

interface Provider{
  string path();
  string toXml(string indent);
}

class ZipProvider: Provider{
  string file;
  string location;

  this(string file,string location){
    this.file=file;
    this.location=location;
  }
  override string path(){
    return file;
  }
  string toXml(string indent){
    return indent ~ `<zip file="` ~ file ~ `" location="` ~ location ~ `"/>`;
  }
}

class DirProvider:Provider{
  string location;
  this(string location){
    this.location=location;
  }
  override string path(){
    return location;
  }
  string toXml(string indent){
    return indent ~ `<dir location="` ~ location ~ `"/>`;
  }
}

class GavJarProvider: Provider{
  string gav;
  string location;
  this(string gav,string location){
    this.gav=gav;
    this.location=location;
  }
  override string path(){
    return gav;
  }
  string toXml(string indent){
    string loc="";
    if (null!=location){
      loc=" location=\""~location~"\" ";
    }
    return indent ~ `<jar gav="` ~ gav ~loc~ `"/>`;
  }
}

unittest{
  auto repo = Repo( "https://repo1.maven.org/maven2","~/.m2/repository");
  auto remoteBui="https://repo1.maven.org/maven2/org/beangle/bundles/beangle-bundles-bui/0.1.7/beangle-bundles-bui-0.1.7.jar";
  assert( remoteBui == repo.remoteUrl( "org.beangle.bundles:beangle-bundles-bui:0.1.7"));
}

unittest{
  auto content=`<?xml version="1.0" encoding="UTF-8"?>
<assets base="~/tmp/static">
  <repository remote="https://repo1.maven.org/maven2"/>
  <contexts>
    <context base="/urp/">
       <dir location="~/.openurp/static"/>
    </context>
    <context base="/my97/">
       <jar gav="org.beangle.bundles:beangle-bundles-my97:4.8"/>
    </context>

    <context base="/bui/">
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.7"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.1.4"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.0"/>
       <jar gav="org.beangle.bundles:beangle-bundles-bui:0.2.1"/>
    </context>
  </contexts>
</assets>`;

  auto config = Config.parse( content);
  assert(config.toXml().canFind( "https://repo1.maven.org/maven2"));
}

