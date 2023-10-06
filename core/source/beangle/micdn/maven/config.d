module beangle.micdn.maven.config;
import std.string;
import dxml.dom;
import std.conv;
import std.file;
import std.stdio;
import vibe.core.log;
import beangle.xml.reader;

class Config {
  /**artifact local repo*/
  immutable string base;
  /**cache the artifacts*/
  immutable bool cacheable;
  /**enable dir list*/
  immutable bool publicList;
  /**candinates remote repos*/
  immutable string[] remoteRepos = [];
  /**default remote repo*/
  immutable string defaultRepo;

  static Sha1Postfix = ".sha1";
  static auto CentralURL = "https://repo1.maven.org/maven2";
  static auto AliyunURL = "https://maven.aliyun.com/nexus/content/groups/public";

  this(string base, bool cacheable, bool publicList, string[] remoteRepos) {
    this.base = base;
    this.cacheable = cacheable;
    this.publicList = publicList;
    this.remoteRepos = to!(immutable(string[]))(remoteRepos);
    this.defaultRepo = remoteRepos[$ - 1];
  }

  public static Config parse(string home, string content) {
    auto dom = parseDOM!simpleXML(content).children[0];
    auto attrs = getAttrs(dom);
    immutable bool cacheable = attrs.get("cacheable", "true").to!bool;
    immutable bool publicList = attrs.get("publicList", "false").to!bool;
    import std.path;

    string base = expandTilde(attrs.get("base", home));
    string[] remoteRepos = [];
    auto remotesEntries = children(dom, "remotes");
    if (!remotesEntries.empty) {
      auto remoteEntries = children(remotesEntries.front, "remote");
      foreach (remoteEntry; remoteEntries) {
        attrs = getAttrs(remoteEntry);
        if ("url" in attrs) {
          remoteRepos.add(attrs["url"]);
        } else if ("alias" in attrs) {
          switch (attrs["alias"]) {
            case "central":
              remoteRepos.add(CentralURL);
              break;
            case "aliyun":
              remoteRepos.add(AliyunURL);
              break;
            default:
              throw new Exception("unknown named repo " ~ attrs["alias"]);
          }
        }
      }
    }
    if (remoteRepos.length == 0) {
      remoteRepos.add(CentralURL);
    }
    return new Config(base, cacheable, publicList, remoteRepos);
  }

  bool download(string uri) {
    if (uri.endsWith(".sha1")) {
      return doDownload(uri);
    } else {
      doDownload(uri ~ ".sha1");
      doDownload(uri);
      int res = verify(uri);
      if (res < 0) {
        remove(uri);
        return false;
      } else {
        return true;
      }
    }
  }

  void remove(string uri) {
    auto sha1 = this.base ~ uri ~ Sha1Postfix;
    auto artifact = this.base ~ uri;
    if (exists(sha1)) {
      logInfo("Remove %s", sha1);
      std.file.remove(sha1);
    }
    if (exists(artifact)) {
      logInfo("Remove %s", artifact);
      std.file.remove(artifact);
    }
  }

  /** verify artifact
   * return 0 is ok. -1 miss match sha1,-2 missing artifact ,-3 missing sha1
   */
  int verify(string uri) {
    auto sha1 = this.base ~ uri ~ Sha1Postfix;
    auto artifact = this.base ~ uri;

    if (!exists(sha1))
      return -1;
    if (!exists(artifact))
      return -2;

    logInfo("Verify %s against sha1", artifact);
    import std.digest.sha;

    File file = File(artifact);
    auto digest = new SHA1Digest();
    foreach (buffer; file.byChunk(4096 * 1024))
      digest.put(buffer);
    ubyte[] result = digest.finish();
    auto hexCalc = toHexString(result).toLower;
    auto sha1InFile = readText(sha1).toLower;
    import std.algorithm;


    auto ok = sha1InFile.indexOf(hexCalc) >= 0;
    if (!ok) {
      logWarn("Miss match sha for %s. sha1file %s and calculated is %s", artifact, sha1InFile, hexCalc);
      return -1;
    } else {
      return 0;
    }
  }

  /** try to download file
   * @return true if local exists
   */
  bool doDownload(string uri) {
    auto local = this.base ~ uri;
    if (exists(local)) {
      return true;
    }
    auto part = local ~ ".part";
    import std.path;

    mkdirRecurse(dirName(local));
    foreach (r; this.remoteRepos) {
      auto remote = r ~ uri;
      try {
        import vibe.inet.urltransfer;

        vibe.inet.urltransfer.download(remote, part);

        if (exists(part) && !exists(local)) {
          rename(part, local);
          logInfo("Downloaded %s", remote);
        }
        break;
      } catch (Exception e) {
        logWarn("Download failure %s %s", remote, e.msg);
      } finally {
        if (exists(part)) {
          std.file.remove(part);
        }
      }
    }
    return exists(local);
  }

}

void add(ref string[] remotes, string remote) {
  remotes.length += 1;
  remotes[$ - 1] = remote;
}

unittest {
  auto content = `<?xml version="1.0" encoding="UTF-8"?>
<maven cacheable="true" >
  <remotes>
    <remote url="https://maven.aliyun.com/nexus/content/groups/public"/>
    <remote alias="central"/>
  </remotes>
</maven>`;

  auto config = Config.parse("~/.m2/repository", content);
  assert(config.remoteRepos.length == 2);
  assert(config.remoteRepos[1] == Config.CentralURL);
}
