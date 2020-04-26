module beangle.micdn.config;

class Config{
    ushort port;
    string uriContext;
    string fileBase;
    Profile[string] profiles;

    this(ushort port,string uriContext,string fileBase){
        this.port=port;
        this.uriContext=uriContext;
        this.fileBase=fileBase;
    }
}

struct Profile{
    string path;
    string owner;
    string key;
    bool publicList;
    bool publicDownload;
}
