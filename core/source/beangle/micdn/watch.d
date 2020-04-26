module beangle.micdn.watch;

import core.time;
import core.sys.posix.unistd;
import core.sys.posix.poll;
import core.sys.linux.sys.inotify;
import std.algorithm;
import std.exception;
import std.file;
import std.stdio;
import std.string;
import beangle.micdn.inotify;

public struct Watch {
    Event[] read(Duration timeout){
        return readImpl( cast(int)timeout.total!"msecs");
    }

    Event[] read(){
        return readImpl( -1);
    }

    public @property int descriptor(){
        return queuefd;
    }
    private void addDir(string root){
        enforce( exists( root));
        add( root,this.mask | IN_CREATE | IN_DELETE_SELF);
        foreach (d; dirEntries( root, SpanMode.breadth)) {
            if (d.isDir && !d.isSymlink) add( d.name,this.mask| IN_CREATE | IN_DELETE_SELF);
        }
    }

    private int add(string path,uint mask){
        import std.conv;
        auto zpath = toStringz( path);
        auto wd =  inotify_add_watch( this.queuefd,zpath, mask);
        if (wd>0){
            paths[wd] = path;
        }
        return wd;
    }

    private void remove(int wd){
        paths.remove( wd);
        enforce( inotify_rm_watch( this.queuefd, wd) == 0, "failed to remove inotify watch");
    }

    private const (char)[] name(ref inotify_event e) {
        auto ptr = cast(const(char)*)(&e.name);
        return fromStringz( ptr);
    }

    private Event[] readImpl(int timeout) {
        pollfd pfd;
        pfd.fd = queuefd;
        pfd.events = POLLIN;

        if (poll( &pfd, 1, timeout) <= 0) return null;
        long len = .read( queuefd, buffer.ptr, buffer.length);// why .
        enforce( len > 0, "failed to read inotify event"); // test why len >0 when no event happen.
        ubyte* head = buffer.ptr;
        events.length = 0;
        events.assumeSafeAppend();
        while (len > 0) {
            auto eptr = cast(inotify_event*)head;
            auto size = (*eptr).sizeof + eptr.len;
            head += size;
            len -= size;
            string path = paths[eptr.wd];
            path ~= "/" ~ name( *eptr);
            auto e = Event( eptr.wd, eptr.mask, eptr.cookie,path );
            if (e.mask & IN_ISDIR) {
                if (e.mask & IN_CREATE) {
                    add( path,this.mask | IN_CREATE | IN_DELETE_SELF);
                } else if (e.mask & IN_DELETE_SELF) {
                    remove( e.wd);
                }
            }
            if (mask & e.mask) {
                events ~= e;
            }
        }
        return events;
    }

    private int queuefd = -1; // inotify event queue file discriptor
    private string[] roots;
    private int mask;
    private string[uint] paths;
    private ubyte[] buffer;
    private Event[] events;

    this(int queuefd,string[] roots,int mask) {
        enforce( queuefd >= 0, "failed to init inotify");
        this.queuefd = queuefd;
        this.mask=mask;
        //see http://man7.org/linux/man-pages/man7/inotify.7.html
        buffer = new ubyte[1024*(inotify_event.sizeof + 256)];
        this.roots=roots;
        foreach (string root;roots){
            this.addDir( root);
        }
    }
    ~this(){
        stop();
    }
    void stop(){
        if (queuefd >= 0) {
            close( queuefd);
            queuefd = -1;
        }
    }
}

public auto watch(string base,int mask) {
    return Watch( inotify_init1( IN_NONBLOCK),[ base],mask);
}

unittest {
    import std.process, std.stdio : writeln;
    executeShell( "rm -rf temp");
    executeShell( "mkdir temp");
    auto monitor = watch( "temp",IN_CREATE | IN_DELETE);
    executeShell( "touch temp/killme");
    auto events = monitor.read();
    assert(events[0].mask == IN_CREATE);
    assert(events[0].path == "temp/killme");

    executeShell( "rm -rf temp/killme");
    events = monitor.read();
    assert(events[0].mask == IN_DELETE);

    // watched directory and new sub-directory is not watched.
    executeShell( "mkdir temp/dir");
    executeShell( "touch temp/dir/victim");
    events = monitor.read();
    assert(events.length == 1);
    assert(events[0].mask == (IN_ISDIR | IN_CREATE));
    assert(events[0].path == "temp/dir");

    //monitor tree
    executeShell( "rm -rf temp");
    executeShell( "mkdir -p temp/dir1");
    executeShell( "mkdir -p temp/dir2");
    monitor = watch( "temp", IN_CREATE | IN_DELETE);
    executeShell( "touch temp/dir1/a.temp");
    executeShell( "touch temp/dir2/b.temp");
    executeShell( "rm -rf temp/dir2");
    auto evs = monitor.read();
    assert(evs.length == 4);
    // a & b files created
    assert(evs[0].mask == IN_CREATE && evs[0].path == "temp/dir1/a.temp");
    assert(evs[1].mask == IN_CREATE && evs[1].path == "temp/dir2/b.temp");
    // b deleted as part of sub-tree
    assert(evs[2].mask == IN_DELETE && evs[2].path == "temp/dir2/b.temp");
    assert(evs[3].mask == (IN_DELETE | IN_ISDIR) && evs[3].path == "temp/dir2");
    evs = monitor.read( 10.msecs);
    assert(evs.length == 0);

    import core.thread;
    auto t = new Thread( (){
        Thread.sleep( 1000.msecs);
        executeShell( "touch temp/dir1/c.temp");
    }).start();
    evs = monitor.read( 10.msecs);
    t.join();
    assert(evs.length == 0);
    evs = monitor.read( 10.msecs);
    assert(evs.length == 1);

    executeShell( "rm -rf temp");
}
