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
import beangle.micdn.asset.repository;
import beangle.micdn.asset.config;

//Config config;
Repository repository;
Server server;
Config config;
void main(string[] args){
  if (args.length<3){
    writeln( "Usage: beangle-micdn-asset path/to/server.xml path/to/config.xml");
    return ;
  }

  /*import etc.linux.memoryerror;
    static if (is(typeof(registerMemoryErrorHandler)))
        registerMemoryErrorHandler();*/
  server = Server.parse( cast(string) std.file.read( args[1]));
  config = Config.parse( cast(string) std.file.read( args[2]));
  repository = Repository.build( config);
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
  if (uri =="/config.xml"){
    res.statusCode=200;
    res.headers["Content-Type"] ="application/xml";
    res.writeBody( config.toXml());
  }else {
    auto rs = repository.get( uri);
    if (null==rs){
      throw new HTTPStatusException( HTTPStatus.notFound);
    }else {
      // dir
      if (isDir( rs[0])){
        if (uri.endsWith( "/")){
          auto content=genListContents( repository.base ~ uri,server.contextPath,uri);
          render!("index.dt",uri,content)( res);
        }else {
          uri=server.contextPath ~ uri;
          res.redirect( req.requestURI.replace( uri, uri ~"/"));
        }
      }else {
        if (rs.length==1){
          sendFile( req,res,rs[0]);
        }else {
          sendFiles( req,res,rs);
        }
      }
    }
  }
}

