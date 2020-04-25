import vibe.core.core;
import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.core.file;
import vibe.web.web;
import std.stdio;
import std.file;
import std.string;
import beangle.micdn.gateway;

void main()
{
    auto router = new URLRouter;
    router.registerWebInterface( new List);

    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.bindAddresses = [ "::1", "127.0.0.1"];
    listenHTTP( settings, router);

    logInfo( "Please open http://127.0.0.1:8080/ in your browser.");
    runApplication();
}

class List{
    FileBrowser browser= new FileBrowser( "/home/chaostone");
    @path( "/*")
    void index(HTTPServerRequest req, HTTPServerResponse res)
    {
        auto uri=req.requestURI;
        auto rs = browser.check( uri);
        if (rs ==0 ){
            throw new HTTPStatusException(HTTPStatus.NotFound);
        }else if (rs == 1 ){ // dir
            if (uri.endsWith( "/")){
                auto content=browser.genListContent( uri);
                render!("index.dt",uri,content);
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
}
