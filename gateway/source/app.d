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

Config config;
Repository repository;

void main()
{
    import etc.linux.memoryerror;
    static if (is(typeof(registerMemoryErrorHandler)))
        registerMemoryErrorHandler();
    config =new Config( 8080,"/micdn","/home/chaostone/tmp");
    repository= new Repository( config.fileBase);
    auto router = new URLRouter( config.uriContext);
    router.get( "*",&index);
    router.post( "*", &upload);

    auto settings = new HTTPServerSettings;
    settings.port = config.port;
    settings.bindAddresses = [ "::1", "127.0.0.1"];
    listenHTTP( settings, router);

    logInfo( "Please open http://127.0.0.1:8080/ in your browser.");
    runApplication();
}

bool checkPassword(string user, string password) @safe{
    return user == "admin" && password == "secret";
}

void index(HTTPServerRequest req, HTTPServerResponse res){
    auto uri =getPath( req);
    auto rs = repository.check( uri);
    if (rs ==0 ){
        throw new HTTPStatusException( HTTPStatus.notFound);
    }else if (rs == 1 ){ // dir
        if (uri.endsWith( "/")){
            Profile profile = config.getProfile( uri);
            if (profile.publicList|| basicAuth( req,res)){
                auto content=repository.genListContent( uri);
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
                if (basicAuth( req,res)){
                    download( req,res,uri);
                    SysTime now=Clock.currTime();
                    import core.time;
                    now.fracSecs= msecs( 0);
                    writeln( "token="~profile.genToken( uri,now)~"&t="~now.toISOString);
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
    if (basicAuth( req,res)){
        auto pf = "file" in req.files;
        enforce( pf !is null, "No file uploaded!");
        import vibe.core.path;
        try moveFile( pf.tempPath, NativePath( repository.base) ~ uri);
        catch (Exception e) {
            logWarn( "Failed to move file to destination folder: %s", e.msg);
            logInfo( "Performing copy+delete instead.");
            copyFile( pf.tempPath, NativePath( repository.base) ~ uri);
        }
        res.writeBody( "File uploaded!", "text/plain");
    }
}

void download(HTTPServerRequest req,  HTTPServerResponse res,string path){
    import vibe.core.path;
    import vibe.http.fileserver;
    sendFile( req,res,NativePath( repository.base ~path),null);
}

bool checkToken(Profile profile,string uri,string token,string timestamp){
    return profile.verifyToken( uri,token,SysTime.fromISOString( timestamp));
}

bool basicAuth(HTTPServerRequest req,HTTPServerResponse res) {
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
