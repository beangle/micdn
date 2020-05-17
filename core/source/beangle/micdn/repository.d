module beangle.micdn.repository;

import std.stdio;
import std.file;
import std.datetime.date;
import std.algorithm;
import std.string;
import std.conv;
import beangle.micdn.db;
import beangle.micdn.config;

class Repository{
    string base;
    MetaDao metaDao;
    bool[string] images;

    this(string b,MetaDao metaDao){
        this.base=b;
        this.metaDao=metaDao;
        images[".jpg"]=true;
        images[".png"]=true;
        images[".gif"]=true;
    }

    int check(string path){
        if (exists( base ~ path)){
            if (isDir( base ~ path)){
                return 1;
            }else {
                return 2;
            }
        }else {
            return 0;
        }
    }

    public string getRealname(Profile profile,string path){
        if(metaDao !is null){
            return metaDao.getFilename( profile,path);
        }else{
            return "";
        }
    }

    auto list(string path){
        auto startIdx= (base ~ path).length;
        if (!path.endsWith( "/")){
            startIdx+=1;
        }
        int size=0;
        foreach (DirEntry entry;dirEntries( base ~ path, SpanMode.shallow)){
            size++;
        }
        FileEntry[] entries= new FileEntry[size];
        int i=0;
        foreach (DirEntry entry;dirEntries( base ~ path, SpanMode.shallow)){
            FileEntry fe= new FileEntry();
            fe.name = entry.name[startIdx ..$];
            fe.isDir= entry.isDir();
            fe.size= entry.size();
            auto st= entry.timeLastModified;
            fe.lastModified =DateTime( st.year,st.month,st.day,st.hour,st.minute,st.second);
            entries[i++]=fe;
        }
        sort( entries);
        return entries;
    }

    auto genListContent(string prefix,string uri){
        auto entries=list( uri);
        import std.array : appender;
        auto app = appender!string();
        auto lastSlash=uri[0 .. $-1 ].lastIndexOf( "/");
        if (lastSlash > -1){
            app.put( "<a href=\"" );
            app.put( prefix);
            app.put( uri[0 .. lastSlash+1]);
            app.put( "\">..</a>\n");
        }
        foreach (entry;entries){
            app.put( entry.toLine());
            app.put( "\n");
        }
        return app.data;
    }

    public BlobMeta create(Profile profile,string tmpfile,string filename,string dir,string owner,string mediaType){
        auto meta= new BlobMeta();
        import std.digest,std.digest.sha;
        auto tmp= File( tmpfile);
        auto shaHex = toHexString( digest!SHA1( tmp.byChunk( 4096 * 1024))).toLower;
        meta.profileId=profile.id;
        meta.owner=owner;
        meta.name=filename;
        meta.size=tmp.size();
        meta.mediaType=mediaType;
        meta.sha=shaHex;
        import std.datetime.systime;
        meta.updatedAt=Clock.currTime();
        import std.path;
        auto filePath ="";
        if (profile.namedBySha){
            auto ext= extension( meta.name);
            if (dir.endsWith( "/")){
                filePath = dir  ~ shaHex ~ ext;
            }else {
                filePath = dir ~ "/" ~ shaHex ~ ext;
            }
        }else {
            if (dir.endsWith( "/")){
                filePath = dir ~ meta.name;
            }else {
                filePath = dir ~ "/" ~ meta.name;
            }
        }
        meta.path=filePath[profile.path.length .. $];
        mkdirRecurse( dirName( this.base ~ profile.path ~ meta.path));
        copy( tmpfile, this.base ~ profile.path ~ meta.path);
        if (metaDao !is null){
            metaDao.remove( profile,meta.path);
            metaDao.create( profile,meta);
        }
        return meta;
    }

    public bool remove(Profile profile,string path){
        if (std.file.exists( this.base ~ path)){
            std.file.remove( this.base ~ path );
            if ( metaDao !is null){
                metaDao.remove( profile,path[profile.path.length..$]);
            }
            return true;
        }else {
            return false;
        }
    }

}

class FileEntry{
    string name;
    bool isDir;
    DateTime lastModified;
    ulong size;

    auto toLine(){
        import std.array : appender;
        auto buf = appender!string();
        buf.put( "<a href=\"");
        buf.put( name);
        if (isDir){
            buf.put( "\\");
        }
        buf.put( "\" >");
        buf.put( name);
        buf.put( "</a>");
        auto href= buf.data;
        ulong padding=0;
        if (name.length < 60){
            padding=(60-name.length)+href.length;
        }
        if (isDir){
            return leftJustify( href,padding,' ') ~ lastModified.toString() ~ rightJustify( "-",30,' ');
        }else {
            return leftJustify( href,padding,' ') ~ lastModified.toString() ~ rightJustify( size.to!string,30,' ');
        }
    }
    public override int opCmp(Object o){
        return cmp( this.name,(cast(FileEntry)o).name);
    }
}

unittest{
    auto entries = new FileEntry[2];
    entries[0]=new FileEntry();
    entries[1]=new FileEntry();
    entries[0].name="av";
    entries[1].name="a";
    sort( entries);
    assert( entries[0].name =="a");
}
