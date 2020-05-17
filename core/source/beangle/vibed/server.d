module beangle.vibed.server;

import dxml.dom;
class Server{
    string[] ips;
    ushort port;
    string contextPath;

    this(string[] ips,ushort port,string contextPath){
        this.ips=ips;
        this.port=port;
        this.contextPath=contextPath;
    }
    public static Server parse(string content){
        import std.conv;
        Server server;
        auto dom = parseDOM!simpleXML( content).children[0];
        auto attrs = getAttrs( dom);
        string hosts ;
        if ("ips" in attrs){
            hosts= attrs.get( "ips","127.0.0.1");
        }else {
            hosts= attrs.get( "hosts","127.0.0.1");
        }
        ushort port = attrs.get( "port","8080").to!ushort;
        auto contextEntries= children( dom,"Context");
        if (contextEntries.empty){
            throw new Exception( "Context element is needed in server.xml.");
        }
        auto contextAttrs = getAttrs( contextEntries.front);
        import std.array;
        return new Server( split( hosts,","),port,contextAttrs["path"]);
    }
    @property
    public string listenAddr(){
        import std.conv;
        return this.ips[0] ~":" ~ port.to!string;
    }
    private static auto getAttrs(T)(ref DOMEntity!T dom){
        string[string] a;
        foreach (at;dom.attributes){
            a[at.name]=at.value;
        }
        return a;
    }
    private static auto children(T)(ref DOMEntity!T dom,string path){
        import std.algorithm;
        return dom.children.filter!(c => c.name==path);
    }

}

unittest{
    auto content=`<?xml version="1.0" encoding="UTF-8"?>
<Server ips="192.168.31.244" port="8081">
  <Context path="/blob" />
</Server>`;
    auto server = Server.parse( content);
    import std.stdio;
    assert(server.ips.length ==1 );
}

