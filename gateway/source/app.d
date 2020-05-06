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
import beangle.micdn.repository;
import beangle.micdn.config;
import beangle.micdn.db;

Config config;
Repository repository;

void main(string[] args){
    if (args.length<2){
        writeln( "Usage: beangle-micdn-gateway path/to/config.xml");
        return ;
    }
    import etc.linux.memoryerror;
    static if (is(typeof(registerMemoryErrorHandler)))
        registerMemoryErrorHandler();
    string s = cast(string) std.file.read( args[1]);
    config = Config.parse( s);
    MetaDao metaDao=null;
    if (!config.dataSourceProps.empty){
        metaDao = new MetaDao( config.dataSourceProps);
    }
    repository= new Repository( config.fileBase,metaDao);
    auto router = new URLRouter( config.uriContext);
    router.get( "*",&index);
    router.post( "*", &upload);
    router.delete_( "*",&remove);
    auto settings = new HTTPServerSettings;
    settings.bindAddresses=[ config.host];
    settings.port = config.port;
    listenHTTP( settings, router);
    logInfo( "Please open http://" ~ config.listenAddr ~ config.uriContext~" in your browser.");
    runApplication( &args);
}

void index(HTTPServerRequest req, HTTPServerResponse res){
    auto uri =getPath( req);
    auto rs = repository.check( uri);
    if (rs ==0 ){
        throw new HTTPStatusException( HTTPStatus.notFound);
    }else if (rs == 1 ){ // dir
        if (uri.endsWith( "/")){
            Profile profile = config.getProfile( uri);
            if (profile.publicList|| basicAuth( req,res,profile)){
                auto content=repository.genListContent( config.uriContext,uri);
                render!("index.dt",uri,content)( res);
            }
        }else {
            import std.array;
            uri=config.uriContext ~ uri;
            res.redirect( req.requestURI.replace( uri, uri ~"/"));
        }
    }else { //file
        Profile profile = config.getProfile( uri);
        if (profile.publicDownload){
            download( req,res,uri);
        }else {
            auto token=("token" in req.query);
            auto t=("t" in req.query);
            if (null==token||null==t){
                if (basicAuth( req,res,profile)){
                    download( req,res,uri);
                }
            }else if (checkToken( profile,uri,*token,*t)){
                download( req,res,uri);
            }else {
                res.statusCode = HTTPStatus.forbidden;
                res.writeBody( "bad token!", "text/plain");
            }
        }
    }
}

void upload(HTTPServerRequest req,   HTTPServerResponse res){
    auto uri =getPath( req);
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
    auto uri = getPath( req);
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

void download(HTTPServerRequest req,  HTTPServerResponse res,string path){
    import vibe.core.path;
    import vibe.http.fileserver;
    sendFile( req,res,NativePath( repository.base ~path),null);
}

bool checkToken(Profile profile,string uri,string token,string timestamp){
    try {
        return profile.verifyToken( uri,token,SysTime.fromISOString( timestamp));
    }catch( Exception e) {
        return false;
    }
}

bool basicAuth(HTTPServerRequest req,HTTPServerResponse res,Profile profile) {
    bool checkPassword(string user, string password) @safe{
        return user == profile.path && password == profile.key;
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

string getPath(HTTPServerRequest req){
    auto uri=req.requestURI;
    if (uri.startsWith( config.uriContext)){
        uri = uri[config.uriContext.length .. $];
    }else {
        throw new HTTPStatusException( HTTPStatus.NotFound);
    }
    auto qIdx=uri.indexOf( "?");
    if (qIdx >0){
        return uri[0..qIdx];
    }else {
        return uri;
    }
}

