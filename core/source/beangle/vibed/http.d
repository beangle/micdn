module beangle.vibed.http;
import std.stdio;

string encodeAttachmentName(string name) @safe{
    import std.array;
    import vibe.textfilter.urlencode;
    auto filename=name.urlEncode();
    auto n=`attachment; filename="{filename}"; filename*=utf-8''{filename}`;
    return n.replace("{filename}",filename);
}

unittest{
    auto s = encodeAttachmentName("早上 好.txt");
    writeln(s ==`attachment; filename="%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt"; filename*=utf-8''%E6%97%A9%E4%B8%8A%20%E5%A5%BD.txt`);
}
