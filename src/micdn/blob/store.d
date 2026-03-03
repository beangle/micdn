/* Copyright (C) 2023 Beangle
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

module micdn.blob.store;
/// 通过 PostgreSQL 访问 blob 元数据表的 DAO 封装。
/// Blob 元数据与物理文件之间的仓库协调层。

import std.algorithm;
import std.conv;
import std.datetime.systime;
import std.file;
import std.stdio;
import std.string;

import vibe.core.log;
import vibe.db.postgresql;

import micdn.model;

class MetaDao {

  PostgresClient client;
  string schema;

  this(const(string[string]) props, const(BlobConfig) config) {
    import std.format;
    import std.conv;

    auto url = format("host=%s dbname=%s user=%s password=%s",
        props["serverName"], props["databaseName"], props["user"], props["password"]);
    auto maximumPoolSize = props.get("maximumPoolSize", "7").to!ushort;
    schema = props["schema"];

    client = new PostgresClient(url, maximumPoolSize);
  }

  /// 删除指定 profile 和路径的元数据记录。
  void remove(const(BlobProfile) profile, string path) {
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "delete from " ~ schema
        ~ ".blb_blob_metas where profile_id=$1 and file_path=$2";
      query.argsVariadic(profile.id, path);
      conn.execParams(query);
    });
  }

  /// 插入 blob 元数据记录，domain_id 取自 profile.domainId。
  public bool create(const(BlobProfile) profile, BlobMeta m) {
    bool success = false;
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "insert into " ~ schema ~ ".blb_blob_metas(id,owner,name,file_size,sha,media_type,profile_id,file_path,updated_at,domain_id) values(datetime_id(),$1,$2,$3,$4,$5,$6,$7,now(),$8)";
      import std.conv;

      query.argsVariadic(m.owner, m.name, m.fileSize.to!long, m.sha,
        m.mediaType, m.profileId, m.filePath, profile.domainId);
      conn.execParams(query);
      success = true;
    });
    return success;
  }

  /// 根据 profile 和路径查询元数据中的原始文件名。
  public string getFilename(const(BlobProfile) profile, string path) {
    string filename = "";
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "select name from " ~ schema
        ~ ".blb_blob_metas where profile_id=$1 and file_path=$2";
      query.argsVariadic(profile.id, path);
      auto r = conn.execParams(query);
      if (r.length > 0) {
        filename = r[0]["name"].as!PGtext;
      }
    });
    return filename;
  }

  /// 域名转 OS 友好目录名：替换 : 为 _
  static string hostnameToDir(string hostname) {
    import std.algorithm;

    return hostname.replace(":", "_");
  }

  /// 路径段规范化：/开头，不/结尾，不能为空
  static string normalizeBase(string s) {
    s = s.strip();
    if (s.empty)
      return s;
    if (!s.startsWith("/"))
      s = "/" ~ s;
    if (s.length > 1 && s.endsWith("/"))
      s = s[0 .. $ - 1];
    return s;
  }

  /// 从数据库加载所有 domain，填充到 repo.domains。
  public void loadAllDomains(BlobRepo repo) {
    client.pickConnection((scope conn) {
      import std.conv;
      import std.array;

      auto r0 = conn.exec("select id,hostname from " ~ schema ~ ".blb_domains");
      foreach (row; 0 .. r0.length) {
        int domainId = r0[row]["id"].as!PGinteger;
        string hostname = r0[row]["hostname"].as!PGtext;
        string domainDir = normalizeBase(hostnameToDir(hostname));
        if (domainDir.empty) {
          logInfo("skip domain with empty domainDir: " ~ hostname);
          continue;
        }

        string[string] keys;
        auto r = conn.exec(
          "select name,key from " ~ schema ~ ".blb_users where domain_id=" ~ domainId.to!string);
        foreach (ur; 0 .. r.length) {
          string name = r[ur]["name"].as!PGtext;
          string key = r[ur]["key"].as!PGtext;
          keys[name] = key;
        }

        BlobProfile[string] profiles;
        auto r2 = conn.exec("select id,base,users,named_by_sha,public_download from "
          ~ schema ~ ".blb_profiles where domain_id=" ~ domainId.to!string);
        foreach (pr; 0 .. r2.length) {
          int id = r2[pr]["id"].as!PGinteger;
          string baseRaw = r2[pr]["base"].as!PGtext;
          string base = normalizeBase(baseRaw);
          if (base.empty) {
            logInfo("skip profile with empty base in domain " ~ hostname);
            continue;
          }
          string users = r2[pr]["users"].as!PGtext;
          bool namedBySha = r2[pr]["named_by_sha"].as!PGboolean;
          bool publicDownload = r2[pr]["public_download"].as!PGboolean;

          string[string] profileKeys;
          if (!users.empty) {
            foreach (u; users.split(",")) {
              if (u in keys) {
                profileKeys[u] = keys[u];
              } else {
                logInfo("ignore illegal user " ~ u ~ " in domain " ~ hostname);
              }
            }
          }
          profiles[base] = new BlobProfile(id, base, profileKeys, namedBySha,
            publicDownload, domainId, domainDir);
        }
        repo.domains[hostname] = new DomainProfile(domainId, hostname, domainDir, profiles, keys);
      }
      logInfo("load " ~ r0.length.to!string ~ " blob domains");
    });
  }
}

/// 多域名 Blob 仓库，按请求域名分别存储到 base 下对应子目录。
class BlobRepo {
  /// 仓库根目录
  const string base;
  /// 元数据访问对象，为空时仅使用文件系统。
  MetaDao metaDao;
  /// 需要特殊处理为图片的扩展名集合。
  bool[string] images;

  ulong maxSize = 50 * 1024 * 1024;
  /// 域名 -> DomainProfile
  DomainProfile[string] domains;

  this(const(BlobConfig) config, MetaDao metaDao) {
    this.base = config.base;
    this.maxSize = config.maxSize;
    this.metaDao = metaDao;
    if (metaDao !is null) {
      metaDao.loadAllDomains(this);
    }
    this.images[".jpg"] = true;
    this.images[".png"] = true;
    this.images[".gif"] = true;
    this.images[".jpeg"] = true;
    this.images[".webp"] = true;
    this.images[".svg"] = true;
    this.images[".ico"] = true;
    this.images[".bmp"] = true;
    this.images[".tiff"] = true;
    this.images[".tif"] = true;
  }

  /// 从 path 中剥离 prefix，得到相对路径。prefix 规范：/开头、不/结尾
  static string pathAfterPrefix(string path, string prefix) {
    return path[prefix.length .. $];
  }

  /// 将逻辑路径转为物理路径，path 须以 / 开头，由调用方保证。
  /// path 包含 profile.base 前缀。
  string toPhysicalPath(const(BlobProfile) profile, string path) const {
    return base ~ profile.domainDir ~ path;
  }

  /** 检查给定 profile 和逻辑路径对应的资源类型。
      Returns: 0=不存在, 1=目录, 2=文件
  */
  int check(const(BlobProfile) profile, string path) const {
    assert(path.startsWith("/"), "path must start with /");
    assert(profile.domainId > 0 && path.startsWith(profile.base),"path must start with profile.base");
    if (path.indexOf("..") > -1)
      return 0;
    auto fullPath = toPhysicalPath(profile, path);
    if (exists(fullPath)) {
      return isDir(fullPath) ? 1 : 2;
    }
    return 0;
  }

  /// 从元数据获取文件的原始下载名，用于 Content-Disposition。
  public string getRealname(const(BlobProfile) profile, string path) {
    if (metaDao !is null) {
      return metaDao.getFilename(profile, path);
    } else {
      return "";
    }
  }

  static BlobRepo build(MicdnConfig config, MetaDao metaDao) {
    return new BlobRepo(config.blob, metaDao);
  }
  /** 将临时上传文件写入仓库，并生成/更新对应的元数据。

      Params:
          profile   = 所属 profile，决定前缀 base 及命名策略
          tmpfile   = 临时文件完整路径
          filename  = 客户端上传的原始文件名
          dir       = profile 下的逻辑目录（以 "/" 结尾或不结尾均可）
          owner     = 业务上的拥有者标识
          mediaType = 媒体类型（Content-Type）

      备注：
         若 `profile.namedBySha` 为真，则文件名使用 SHA1 摘要加扩展名，
         否则直接使用原始文件名。
  */
  public BlobMeta create(const(BlobProfile) profile, string tmpfile,
      string filename, string dir, string owner, string mediaType) {
    assert(profile.domainId > 0 && dir.startsWith(profile.base), "path must start with profile.base");

    auto meta = new BlobMeta();
    import std.digest, std.digest.sha;

    auto tmp = File(tmpfile);
    auto shaHex = toHexString!(LetterCase.lower)(digest!SHA1(tmp.byChunk(4096 * 1024))).idup;
    meta.profileId = profile.id;
    meta.owner = owner;
    meta.name = filename;
    meta.fileSize = tmp.size();
    meta.mediaType = mediaType;
    meta.sha = shaHex;
    import std.datetime.systime;

    meta.updatedAt = Clock.currTime();
    import std.path;

    auto filePath = "";
    if (profile.namedBySha) {
      auto ext = extension(meta.name);
      if (dir.endsWith("/")) {
        filePath = dir ~ shaHex ~ ext;
      } else {
        filePath = dir ~ "/" ~ shaHex ~ ext;
      }
    } else {
      if (dir.endsWith("/")) {
        filePath = dir ~ meta.name;
      } else {
        filePath = dir ~ "/" ~ meta.name;
      }
    }
    meta.filePath = pathAfterPrefix(filePath, profile.base);
    auto physicalPath = toPhysicalPath(profile, filePath);
    mkdirRecurse(dirName(physicalPath));
    copy(tmpfile, physicalPath);
    if (metaDao !is null) {
      metaDao.remove(profile, meta.filePath);
      metaDao.create(profile, meta);
    }
    return meta;
  }

  /** 删除指定路径对应的文件及其元数据。

      Params:
          profile = 所属 profile
          path   = 相对于仓库根目录的完整路径（包含 profile.base）

      Returns:
          true  = 删除成功，false = profile 无效或文件不存在
  */
  public bool remove(const(BlobProfile) profile, string path) {
    assert(profile.domainId > 0 && path.startsWith(profile.base), "path must start with profile.base");

    auto fullPath = toPhysicalPath(profile, path);
    if (std.file.exists(fullPath)) {
      std.file.remove(fullPath);
      if (metaDao !is null) {
        metaDao.remove(profile, pathAfterPrefix(path, profile.base));
      }
      return true;
    }
    return false;
  }

  /// 获取域名对应的 DomainProfile，无则返回 null。
  const(DomainProfile)* getDomain(string hostname) const {
    return hostname in domains;
  }

  /// 根据 hostname 和 path 获取匹配的 BlobProfile，无匹配 domain 时返回 defaultProfile。
  const(BlobProfile) getProfile(string hostname, string path) const {
    auto domain = hostname in domains;
    return domain !is null ? (*domain).getProfile(path) : BlobProfile.defaultProfile;
  }
}
