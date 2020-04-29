module beangle.micdn.repository;

import std.stdio;
import std.file;
import std.datetime.date;
import std.algorithm;
import std.string;
import std.conv;

class Repository{
    string base;

    this(string b){
        this.base=b;
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

    auto list(string path)
    {
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
        return entries;
    }

    auto genListContent(string prefix,string uri){
        auto entries=list( uri);
        import std.array : appender;
        auto app = appender!string();
        auto lastSlash=uri[0 .. $-1 ].lastIndexOf( "/");
        if (lastSlash > -1){
            app.put( "<a href=\"" );
            app.put(prefix);
            app.put(uri[0 .. lastSlash+1]);
            app.put("\">..</a>\n");
        }
        foreach (entry;entries){
            app.put( entry.toLine());
            app.put( "\n");
        }
        return app.data;
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
        buf.put("<a href=\"");
        buf.put(name);
        if (isDir){
            buf.put("\\");
        }
        buf.put("\" >");
        buf.put(name);
        buf.put("</a>");
        auto href= buf.data;
        ulong padding=0;
        if (name.length < 60){
            padding=(60-name.length)+href.length;
        }
        if (isDir){
            return leftJustify( href,padding,' ') ~ lastModified.toString() ~ rightJustify( "-",30,' ');
        }else {
            return leftJustify( href,padding,' ') ~ lastModified.toString() ~ rightJustify(size.to!string,30,' ');
        }
    }
}
