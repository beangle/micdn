module micdn.asset;
/// 根据配置构建/刷新本地静态资源仓库目录结构。

import std.file;
import std.path;
import std.string;

import vibe.core.log;

import micdn.fs.file;
import micdn.model;

class AssetRepo {
  const string base;
  /**enable dir list*/
  const bool publicList;
  this(string base, bool publicList) {
    this.base = base;
    this.publicList = publicList;
  }

  string[] get(string uri) const {
    if (uri.indexOf("..") > -1)
      return null;
    auto files = resolve(uri);
    for (int i = 0; i < files.length; i++) {
      auto location = base ~ files[i];
      if (exists(location)) {
        files[i] = location;
      } else {
        logWarn("Cannot find %s", location);
        return null;
      }
    }
    return files;
  }

  static string[] resolve(string uri) {
    auto commaIdx = uri.indexOf(',');
    if (commaIdx > 0) {
      auto lastDotIdx = lastIndexOf(uri, '.');
      auto extension = uri[lastDotIdx .. $];
      string path = uri[0 .. commaIdx];
      auto lastSlashIdx = lastIndexOf(path, '/');
      path = path[0 .. lastSlashIdx + 1];
      string[] names = split(uri[(lastSlashIdx + 1) .. lastDotIdx], ',');
      for (int i = 0; i < names.length; i++) {
        names[i] = path ~ names[i] ~ extension;
      }
      return names;
    } else {
      return [uri];
    }
  }

  static AssetRepo build(MicdnConfig config) {
    auto asset = config.asset;
    auto repo = config.maven;
    auto base = asset.base;
    if (exists(base)) {
      setWritable(base);
      //rmdirRecurse( base);
    }
    mkdirRecurse(base);
    logInfo("Building repository at %s", base);
    foreach (c; asset.bundles) {
      auto bundlePath = "/" ~ c.name;
      foreach (p; c.providers) {
        if (DirProvider dp = cast(DirProvider) p) {
          auto bundleBase = base ~ "/" ~ c.name;
          if (exists(dp.location)) {
            if (exists(bundleBase)) {
              remove(bundleBase);
            }
            logInfo("Linking " ~ dp.location ~ " to " ~ bundleBase);
            //FIXME
            //symlink(dp.location, bundleBase);
          } else {
            logWarn("Cannot link " ~ dp.location ~ " to " ~ bundleBase);
          }
        } else if (GavJarProvider gap = cast(GavJarProvider) p) {
          string local = repo.localFile(gap.gav);
          string location = gap.location;
          if (null == location) {
            if (gap.gav.startsWith("org.webjars")) {
              location = "META-INF/resources/webjars";
            } else {
              location = "META-INF/resources";
            }
          }

          location ~= bundlePath;
          if (exists(local)) {
            mount(base, local,bundlePath, location);
          } else if (!local.endsWith("SNAPSHOT.jar")) {
            string[] remotes = repo.remoteUrls(gap.gav);
            mkdirRecurse(dirName(local));
            foreach (remote; remotes) {
              logInfo("Downloading %s", remote);
              import micdn.web.file;

              if (curlDownload(remote, local)) {
                mount(base, local,bundlePath, location);
                break;
              }
            }
          } else {
            logWarn("Cannot resolve %s,ignore it.", gap.gav);
          }
        } else if (ZipProvider zp = cast(ZipProvider) p) {
          mount(base, zp.file, bundlePath, zp.dir);
        } else {
          //throw new R
        }
      }
    }
    setReadOnly(base);
    return new AssetRepo(base,config.asset.publicList);
  }

  private static void mount(string base, string zipfile, string bundlePath, string dir) {
    logInfo("Mounting %s", zipfile);
    auto count = refreshUnzip(zipfile, base ~ bundlePath, dir);
    if (count == 0) {
      logWarn("Cannot find %s in %s", dir, zipfile);
    }
  }
}
