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
    repository= new Repository( config.fileBase);
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
            import std.conv;
            bool reserveName=req.form.get( "reserveName","true").to!bool;
            auto meta= new BlobMeta();

            auto tmp = File( pf.tempPath.toNativeString);
            import std.digest,std.digest.sha;
            auto shaHex = toHexString( digest!SHA1( tmp.byChunk( 4096 * 1024))).toLower;
            meta.base=profile.path;
            meta.owner=owner;
            meta.name=pf.toString;
            meta.size=tmp.size();
            meta.sha=shaHex;
            meta.updatedAt=Clock.currTime();
            import std.path;
            auto fullUri ="";
            if (reserveName){
                if (uri.endsWith( "/")){
                    fullUri = uri ~ meta.name;
                }else {
                    fullUri = uri ~ "/" ~ meta.name;
                }
            }else {
                auto ext= extension( meta.name);
                if (uri.endsWith( "/")){
                    fullUri = uri  ~ shaHex ~ ext;
                }else {
                    fullUri = uri ~ "/" ~ shaHex ~ ext;
                }
            }

            meta.path=fullUri[profile.path.length .. $];
            import vibe.inet.mimetypes;
            meta.mediaType=getMimeTypeForFile( meta.name);
            mkdirRecurse(dirName(repository.base ~ profile.path ~ meta.path));
            copyFile( pf.tempPath, NativePath( repository.base ~ profile.path ~ meta.path),true);
            //redirect to log
            logInfo( "upload " ~ meta.toJson() );

            res.writeBody( meta.toJson(), "application/json");
        }catch (Exception e) {
            logInfo( "Performing copy failed.Caurse %s",e.msg);
            res.statusCode = HTTPStatus.internalServerError;
            res.writeBody( e.msg, "text/plain");
        }
    }
}

void remove(HTTPServerRequest req,   HTTPServerResponse res){
    auto uri =getPath( req);
    Profile profile = config.getProfile( uri);
    if (basicAuth( req,res,profile)){
        string msg="remove success";
        try{
            if (std.file.exists( repository.base ~ uri)){
                std.file.remove( repository.base ~ uri );
                logInfo( "remove "~uri);
                res.writeBody( "File removed!", "text/plain");
            }else {
                res.writeBody( "File donot exists!", "text/plain");
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

