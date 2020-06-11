module beangle.vibed.http;

import vibe.http.server;
import vibe.core.path;
import vibe.core.file;
import vibe.core.stream;
import vibe.inet.mimetypes;
import vibe.inet.message;

import std.stdio;
import std.datetime;
import std.typecons;
import std.conv;
import std.string;
import std.algorithm;
import std.exception;
import std.ascii : isWhite;

string encodeAttachmentName(string name) @safe{
    import std.array;
    import vibe.textfilter.urlencode;
    auto filename=name.urlEncode();
    auto n=`attachment; filename="{filename}"; filename*=utf-8''{filename}`;
    return n.replace( "{filename}",filename);
}

/**
 * https://tools.ietf.org/html/rfc7233
 * Range can be in form "-\d", "\d-" or "\d-\d"
 */
ulong[2] parseRange(string range,ulong maxSize) @safe{
    if (range.canFind( ','))
        throw new HTTPStatusException( HTTPStatus.notImplemented);
    auto s = range.split( "-");
    if (s.length != 2)
        throw new HTTPStatusException( HTTPStatus.badRequest);
    ulong start = 0;
    ulong end = 0;
    try {
        if (s[0].length) {
            start = s[0].to!ulong;
            end = s[1].length ? s[1].to!ulong : (maxSize-1);
        } else if (s[1].length) {
            end = (maxSize-1);
            auto len = s[1].to!ulong;
            if (len >= end) start = 0;
            else start = end - len + 1;
        } else {
            throw new HTTPStatusException( HTTPStatus.badRequest);
        }
    } catch (ConvException) {
        throw new HTTPStatusException( HTTPStatus.badRequest);
    }
    if (end >= maxSize)   end = maxSize-1;
    if (start > end)  start = end;
    return [ start,end];
}

unittest{
    auto s = encodeAttachmentName( "早上 好.txt");
    writeln( s ==`attachment; filename="%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt"; filename*=utf-8''%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt`);
    auto r1= parseRange( "0-1",2);
    assert(r1 ==[ 0,1]);

    auto r2= parseRange( "9500-",10000);
    auto r3= parseRange( "-500",10000);
    assert(r2 == r3);

    auto r4= parseRange( "9500-100002",10000);
    assert( r2 == r4);

    auto r5= parseRange( "10000-100002",10000);
    assert(r5 ==[ 9999,9999]);
}

class CacheSetting {
    Duration maxAge = 7.days;

    string cacheControl = null;

    void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath) preWriteCallback = null;
}

CacheSetting default_settings ;
static this(){
    default_settings = new CacheSetting();
}

import vibe.http.fileserver;
void sendFile(scope HTTPServerRequest req, scope HTTPServerResponse res,string path, const CacheSetting settings = null){
    if (settings) {
        sendFileImpl( req, res,  NativePath( path), settings);
    }else {
        sendFileImpl( req, res,  NativePath( path), default_settings);
    }

}

private void sendFileImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, NativePath path, const CacheSetting settings = null){
    auto pathstr = path.toNativeString();
    if (!existsFile( pathstr))  throw new HTTPStatusException( HTTPStatus.NotFound);

    FileInfo dirent;
    try dirent = getFileInfo( pathstr);
    catch(Exception){
        throw new HTTPStatusException( HTTPStatus.InternalServerError, "Failed to get information for the file due to a file system error.");
    }

    if (dirent.isDirectory) {
        throw new HTTPStatusException( HTTPStatus.NotFound);
    }

    if (handleCacheFile( req, res, dirent, settings.cacheControl, settings.maxAge)) {
        return ;
    }

    if (!("Content-Type" in res.headers)){
        res.headers["Content-Type"] = res.headers.get( "Content-Type", getMimeTypeForFile( pathstr));
    }
    res.headers.addField( "Accept-Ranges", "bytes");
    ulong rangeStart = 0;
    ulong rangeEnd = 0;
    auto prange = "Range" in req.headers;

    if (prange) {
        auto range = (*prange).chompPrefix( "bytes=");
        auto startend=parseRange( range,dirent.size);
        rangeStart =startend[0];
        rangeEnd = startend[1];
        res.headers["Content-Length"] = to!string( rangeEnd - rangeStart + 1);
        res.headers["Content-Range"] = "bytes %s-%s/%s".format( rangeStart < rangeEnd ? rangeStart : rangeEnd, rangeEnd, dirent.size);
        res.statusCode = HTTPStatus.partialContent;
    } else
        res.headers["Content-Length"] = dirent.size.to!string;

    if (settings.preWriteCallback) settings.preWriteCallback( req, res, pathstr);

    if ( res.isHeadResponse() ){
        res.writeVoidBody();
        return ;
    }
    FileStream fil;
    try {
        fil = openFile( path);
    } catch( Exception e ){
        return ;
    }
    scope(exit) fil.close();

    if (prange) {
        fil.seek( rangeStart);
        fil.pipe( res.bodyWriter, rangeEnd - rangeStart + 1);
    } else {
        res.writeRawBody( fil);
    }
}
