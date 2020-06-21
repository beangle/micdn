import vibe.core.core;
import vibe.core.log;
import vibe.core.file;
import vibe.http.router;
import vibe.http.server;
import vibe.web.web;
import std.stdio;
import std.file;
import std.string;
import std.exception;
import beangle.web;
import beangle.web.file;
import beangle.web.filebrowser;
import beangle.web.server;
import beangle.micdn.maven.config;

Server server;
Config config;
void main(string[] args){
  if (args.length<3){
    writeln( "Usage: " ~ args[0] ~ " --server path/to/server.xml --config path/to/config.xml");
    return ;
  }

  server = getServer();
  config = Config.parse( getConfigXml( "/micdn/maven.xml"));
  auto router = new URLRouter( server.contextPath);
  router.get( "*",&index);

  auto settings = new HTTPServerSettings;
  settings.bindAddresses= server.ips;
  settings.port = server.port;
  settings.serverString=null;

  listenHTTP( settings, router);
  logInfo( "Please open http://" ~ server.listenAddr ~ server.contextPath~" in your browser.");
  runApplication( &args);
}

void index(HTTPServerRequest req, HTTPServerResponse res){
  auto uri =getPath( server.contextPath, req);
  auto file = config.base ~ uri;
  import std.stdio;
  if (exists( file)){
    if (isDir( file)){
      if (uri.endsWith( "/")){
        auto content=genListContents( config.base ~ uri,server.contextPath,uri);
        render!("index.dt",uri,content)( res);
      }else {
        uri=server.contextPath ~ uri;
        res.redirect( req.requestURI.replace( uri, uri ~"/"));
      }
    }else {
      sendFile( req,res,file);
    }
  }else {
    if (config.cacheable){
      auto local = config.base ~ uri;
      auto tmp=deleteme();
      foreach (r;config.remoteRepos){
        auto remote= r ~ uri;
        try{
          import vibe.inet.urltransfer;
          download( remote,tmp);
          import std.path;
          mkdirRecurse( dirName( local));
          copy( tmp,local);
          logInfo( "Downloaded %s", remote);
          break ;
        }catch(Exception e){
          logWarn( "Download failure %s %s",remote,e.msg);
        }finally{
          std.file.remove( tmp);
        }
      }
      if (exists( local)){
        sendFile( req,res,file);
      }else {
        throw new HTTPStatusException( HTTPStatus.notFound);
      }
    }else {
      res.redirect( config.defaultRepo ~ uri);
    }
  }
}

