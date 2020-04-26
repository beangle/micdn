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
import beangle.micdn.gateway;
import beangle.micdn.config;

Config config;
FileBrowser browser;

void main()
{
    import etc.linux.memoryerror;
    static if (is(typeof(registerMemoryErrorHandler)))
        registerMemoryErrorHandler();
    config =new Config( 8080,"/micdn","/home/chaostone/tmp");
    browser= new FileBrowser( config.fileBase);
    auto router = new URLRouter( config.uriContext);
    router.get( "*",&index);

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

void index(HTTPServerRequest req, HTTPServerResponse res)
{
    auto uri=req.requestURI;
    if (uri.startsWith( config.uriContext)){
        uri = uri[config.uriContext.length .. $];
    }else {
        throw new HTTPStatusException( HTTPStatus.NotFound);
    }
    auto rs = browser.check( uri);
    if (rs ==0 ){
        throw new HTTPStatusException( HTTPStatus.NotFound);
    }else if (rs == 1 ){ // dir
        if (uri.endsWith( "/")){
            import std.functional : toDelegate;
            if (auth( req,res,toDelegate( &checkPassword))){
                auto content=browser.genListContent( uri);
                render!("index.dt",uri,content)( res);
            }
        }else {
            res.redirect( uri ~"/");
        }
    }else { //file
        FileStream fil;
        try {
            fil = openFile( browser.base ~ uri);
        } catch( Exception e ){
            logInfo( e.toString());
        }
        scope(exit) fil.close();
        res.writeRawBody( fil);
    }
}

bool auth(HTTPServerRequest req,HTTPServerResponse res,PasswordVerifyCallback pwcheck) {
    if (!checkBasicAuth( req, pwcheck)) {
        res.statusCode = HTTPStatus.unauthorized;
        res.contentType = "text/plain";
        res.headers["WWW-Authenticate"] = "Basic realm=\"micdn\"";
        res.bodyWriter.write( "Authorization required");
        return false;
    }else {
        return true;
    }
}

/+
  这个类不能有带有参数的构造函数，否则编译不通过。
  也不能有this(){}这种形式的参数，否则运行巨慢，最后异常退出。
+/
class List{
}
