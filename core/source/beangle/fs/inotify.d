module beangle.fs.inotify;
import core.sys.linux.sys.inotify;

public struct Event{
  int wd;// watch descriptor
  uint mask; // watch event set
  uint cookie;
  string path;
  string toString(){
    import std.array : appender;
    import std.conv;
    auto buf = appender!string();
    buf.put("{wd:");
    buf.put(wd.to!string);
    buf.put(",path:\"");
    buf.put(path);
    buf.put("\",mask:");
    buf.put(mask.to!string);
    buf.put(",events:\"");
    buf.put(eventNames(mask));
    buf.put("\",cookie:");
    buf.put(cookie.to!string);
    buf.put("}");
    return buf.data;
  }
}

string eventNames(uint events, char sep=','){
  import std.array : appender;
  import std.conv;
  auto buf = appender!string();
  if ( IN_ACCESS & events ) {
    buf.put(sep);
    buf.put("ACCESS" );
  }
  if ( IN_MODIFY & events ) {
    buf.put(sep );
    buf.put("MODIFY" );
  }
  if ( IN_ATTRIB & events ) {
    buf.put(sep );
    buf.put("ATTRIB" );
  }
  if ( IN_CLOSE_WRITE & events ) {
    buf.put(sep );
    buf.put("CLOSE_WRITE" );
  }
  if ( IN_CLOSE_NOWRITE & events ) {
    buf.put(sep );
    buf.put("CLOSE_NOWRITE" );
  }
  if ( IN_OPEN & events ) {
    buf.put(sep );
    buf.put("OPEN" );
  }
  if ( IN_MOVED_FROM & events ) {
    buf.put(sep );
    buf.put("MOVED_FROM" );
  }
  if ( IN_MOVED_TO & events ) {
    buf.put(sep );
    buf.put("MOVED_TO" );
  }
  if ( IN_CREATE & events ) {
    buf.put(sep );
    buf.put("CREATE" );
  }
  if ( IN_DELETE & events ) {
    buf.put(sep );
    buf.put("DELETE" );
  }
  if ( IN_DELETE_SELF & events ) {
    buf.put(sep );
    buf.put("DELETE_SELF" );
  }
  if ( IN_UNMOUNT & events ) {
    buf.put(sep );
    buf.put("UNMOUNT" );
  }
  if ( IN_Q_OVERFLOW & events ) {
    buf.put(sep );
    buf.put("Q_OVERFLOW" );
  }
  if ( IN_IGNORED & events ) {
    buf.put(sep );
    buf.put("IGNORED" );
  }
  if ( IN_CLOSE & events ) {
    buf.put(sep );
    buf.put("CLOSE" );
  }
  if ( IN_MOVE_SELF & events ) {
    buf.put(sep );
    buf.put("MOVE_SELF" );
  }
  if ( IN_ISDIR & events ) {
    buf.put(sep );
    buf.put("ISDIR" );
  }
  if ( IN_ONESHOT & events ) {
    buf.put(sep );
    buf.put("ONESHOT" );
  }
  return buf.data[1..$];
}



