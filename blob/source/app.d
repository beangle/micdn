import vibe.core.core;
import vibe.core.log;
import vibe.core.file;
import vibe.http.router;
import vibe.http.server;
import vibe.http.auth.basic_auth;
import vibe.web.web;
import std.stdio;
import std.file;
import std.string;
import std.exception;
import std.datetime.systime;
import beangle.micdn.blob.repository;
import beangle.micdn.blob.config;
import beangle.micdn.blob.db;
import beangle.web;
import beangle.web.server;
import beangle.web.file;
import beangle.web.filebrowser;

Config config;
Repository repository;
Server server;

void main(string[] args){
  if (args.length<3){
    writeln( "Usage: " ~ args[0] ~ " --server path/to/server.xml --config path/to/config.xml");
    return ;
  }

  /*import etc.linux.memoryerror;
    static if (is(typeof(registerMemoryErrorHandler)))
        registerMemoryErrorHandler();*/
  server = getServer();
  config = Config.parse( getConfigXml( "/micdn/blob.xml"));
  MetaDao metaDao=null;
  if (!config.dataSourceProps.empty){
    metaDao = new MetaDao( config.dataSourceProps);
    metaDao.loadProfiles( config);
  }
  repository = new Repository( config.base,metaDao);
  auto router = new URLRouter( server.contextPath);
  router.get( "*",&index);
  router.post( "*", &upload);
  router.delete_( "*",&remove);

  auto settings = new HTTPServerSettings;
  settings.maxRequestSize=config.maxSize;
  settings.bindAddresses= server.ips;
  settings.port = server.port;
  settings.serverString=null;

  listenHTTP( settings, router);
  logInfo( "Please open http://" ~ server.listenAddr ~ server.contextPath~" in your browser.");
  runApplication( &args);
}

void index(HTTPServerRequest req, HTTPServerResponse res){
  auto uri =getPath( server.contextPath, req);
  auto rs = repository.check( uri);
  if (rs ==0 ){
    throw new HTTPStatusException( HTTPStatus.notFound);
  }else if (rs == 1 ){ // dir
    if (config.publicList){
      if (uri.endsWith( "/")){
        Profile profile = config.getProfile( uri);
        auto content=genListContents( repository.base~uri,server.contextPath,uri);
        render!("index.dt",uri,content)( res);
      }else {
        import std.array;
        uri=server.contextPath ~ uri;
        res.redirect( req.requestURI.replace( uri, uri ~"/"));
      }
    }else {
      throw new HTTPStatusException( HTTPStatus.notFound);
    }
  }else { //file
    Profile profile = config.getProfile( uri);
    if (profile.publicDownload){
      download( profile, req,res,uri);
    }else {
      auto token=("token" in req.query);
      auto t=("t" in req.query);
      auto user=("u" in req.query);
      if (null==user || null==token || null==t){
        if (basicAuth( req,res,profile)){
          download( profile, req,res,uri);
        }
      }else if (checkToken( profile,uri,*user,profile.keys.get( *user,""),*token,*t)){
        download( profile, req,res,uri);
      }else {
        res.statusCode = HTTPStatus.forbidden;
        res.writeBody( "bad token!", "text/plain");
      }
    }
  }
}

void upload(HTTPServerRequest req,   HTTPServerResponse res){
  auto uri =getPath( server.contextPath,req);
  Profile profile = config.getProfile( uri);
  if (basicAuth( req,res,profile)){
    auto pf = "file" in req.files;
    enforce( pf !is null, "No file uploaded!");
    import vibe.core.path;
    try{
      string owner =req.form.get( "owner","--");
      import vibe.inet.mimetypes;
      auto mediaType=getMimeTypeForFile( pf.toString);
      auto meta = repository.create( profile,pf.tempPath.toNativeString,pf.toString,uri,owner,mediaType);
      logInfo( "upload " ~ profile.path ~ meta.path ~ " at " ~ meta.updatedAt.toISOExtString ~ "(" ~ meta.owner ~ ")" );
      res.writeBody( meta.toJson(), "application/json");
    }catch (Exception e) {
      logInfo( "Performing copy failed.Caurse %s",e.msg);
      res.statusCode = HTTPStatus.internalServerError;
      res.writeBody( e.msg, "text/plain");
    }
  }
}

void remove(HTTPServerRequest req,   HTTPServerResponse res){
  auto uri = getPath( server.contextPath, req);
  Profile profile = config.getProfile( uri);
  if (basicAuth( req,res,profile)){
    try{
      if (repository.remove( profile,uri)){
        logInfo( "remove "~uri ~ " at " ~ Clock.currTime().toISOExtString);
        res.writeBody( "File removed!", "text/plain");
      }else {
        res.writeBody( "File is not existed!", "text/plain");
      }
    }catch (Exception e) {
      logInfo( "Performing remove failed.Caurse %s",e.msg);
      res.statusCode = HTTPStatus.internalServerError;
      res.writeBody( e.msg, "text/plain");
    }
  }
}

//fixme for realname detection
void download(Profile profile,HTTPServerRequest req,  HTTPServerResponse res,string path){
  import std.path;
  auto ext=extension( path);
  if (ext in repository.images){
    sendFile( req,res,  repository.base ~path,null);
  }else {
    auto realname = repository.getRealname( profile,path[profile.path.length ..$]);
    if (realname.length > 0){
      void setContextDisposition(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath)@safe{
        res.headers["Content-Disposition"]=encodeAttachmentName( realname);
      }
      auto settings=new CacheSetting;
      settings.preWriteCallback = &setContextDisposition;
      sendFile( req,res, repository.base ~path,settings);
    }else {
      sendFile( req,res, repository.base ~path,null);
    }
  }
}

bool checkToken(Profile profile,string uri,string user,string key,string token,string timestamp){
  try {
    return profile.verifyToken( uri,user,key,token,SysTime.fromISOString( timestamp));
  }catch( Exception e) {
    return false;
  }
}

bool basicAuth(HTTPServerRequest req,HTTPServerResponse res,Profile profile) {
  bool checkPassword(string user, string password) @safe{
    return !user.empty && !password.empty && profile.keys.get( user,"") == password;
  }
  import std.functional : toDelegate;
  if (!checkBasicAuth( req, toDelegate( &checkPassword))) {
    res.statusCode = HTTPStatus.unauthorized;
    res.contentType = "text/plain";
    res.headers["WWW-Authenticate"] = "Basic realm=\"micdn\"";
    res.bodyWriter.write( "Authorization required");
    return false;
  }else {
    return true;
  }
}
