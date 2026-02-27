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
  int domainId;

  this(const(string[string]) props, const(BlobConfig) config) {
    import std.format;
    import std.conv;

    auto url = format("host=%s dbname=%s user=%s password=%s",
        props["serverName"], props["databaseName"], props["user"], props["password"]);
    auto maximumPoolSize = props.get("maximumPoolSize", "7").to!ushort;
    schema = props["schema"];

    client = new PostgresClient(url, maximumPoolSize);
  }

  void remove(const(BlobProfile) profile, string path) {
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "delete from " ~ schema
        ~ ".blb_blob_metas where profile_id=$1 and file_path=$2";
      query.argsVariadic(profile.id, path);
      conn.execParams(query);
    });
  }

  public bool create(const(BlobProfile) profile, BlobMeta m) {
    bool success = false;
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "insert into " ~ schema ~ ".blb_blob_metas(id,owner,name,file_size,sha,media_type,profile_id,file_path,updated_at,domain_id) values(datetime_id(),$1,$2,$3,$4,$5,$6,$7,now(),$8)";
      import std.conv;

      query.argsVariadic(m.owner, m.name, m.fileSize.to!long, m.sha,
        m.mediaType, m.profileId, m.filePath, this.domainId);
      conn.execParams(query);
      success = true;
    });
    return success;
  }

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

  public void loadProfiles(BlobRepo repo) {
    client.pickConnection((scope conn) {
      QueryParams query;
      query.sqlCommand = "select  id from " ~ schema ~ ".blb_domains where hostname=$1";
      query.argsVariadic(repo.hostname);
      auto r0 = conn.execParams(query);
      for (auto row = 0; row < r0.length; row++) {
        this.domainId = r0[row]["id"].as!PGinteger;
        break;
      }
      if (this.domainId == 0) {
        throw new Exception("cannot find domain with hostname " ~ repo.hostname);
      }
      import std.conv;

      auto r = conn.exec(
        "select name,key from " ~ schema ~ ".blb_users where domain_id=" ~ domainId.to!string);
      for (auto row = 0; row < r.length; row++) {
        string name = r[row]["name"].as!PGtext;
        string key = r[row]["key"].as!PGtext;
        repo.keys[name] = key;
      }
      auto r2 = conn.exec("select id,base,users,named_by_sha,public_download from "
        ~ schema ~ ".blb_profiles where domain_id=" ~ this.domainId.to!string);
      for (auto row = 0; row < r2.length; row++) {
        int id = r2[row]["id"].as!PGinteger;
        string base = r2[row]["base"].as!PGtext;
        string users = r2[row]["users"].as!PGtext;
        bool namedBySha = r2[row]["named_by_sha"].as!PGboolean;
        bool publicDownload = r2[row]["public_download"].as!PGboolean;
        import std.array;

        string[string] profileKeys;
        if (!users.empty) {
          foreach (u; users.split(",")) {
            if (u in repo.keys) {
              profileKeys[u] = repo.keys[u];
            } else {
              logInfo("ignore illegal user " ~ u);
            }
          }
        }
        repo.profiles[base] = new BlobProfile(id, base, profileKeys, namedBySha, publicDownload);
      }
      logInfo("find " ~ r2.length.to!string ~ " blob profiles");
    });
  }
}

/// 单个 Blob 仓库，负责在磁盘目录与数据库元数据之间做协调。
class BlobRepo {
  /// 仓库根目录（实际文件存放的根路径，以 "/" 结尾）。
  const string base;
  /// 元数据访问对象，为空时仅使用文件系统，不记录数据库。
  MetaDao metaDao;
  /// 需要特殊处理为图片的扩展名集合。
  bool[string] images;
  /**enable dir list*/
  const bool publicList;
  /**upload file limit*/
  ulong maxSize = 50 * 1024 * 1024; //default 50m
  /**url profile for management*/
  BlobProfile[string] profiles;
  /**every key for profile*/
  string[string] keys;

  string hostname="localhost";

  private BlobProfile defaultProfile = new BlobProfile(0, "", null, false, false);
  /** 构造一个仓库。

      Params:
          b       = 仓库根目录（如 "/var/blob/"）
          metaDao = 元数据 DAO，可为空表示不持久化元数据
  */
  this(const(string) base, const(bool) publicList, const(ulong) maxSize, const(BlobProfile[string]) profiles,
   const(string[string]) keys, MetaDao metaDao) {
    this.base = base;
    this.publicList = publicList;
    this.maxSize = maxSize;
    this.profiles = profiles.dup;
    this.keys = keys.dup;
    this.metaDao = metaDao;
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
    if(metaDao !is null) {
      metaDao.loadProfiles(this);
    }
  }

  /** 检查给定逻辑路径对应的资源类型。

      Returns:
         0 = 不存在或路径非法（包含 ".."）
         1 = 目录
         2 = 普通文件
  */
  int check(string path) const {
    if (path.indexOf("..") > -1)
      return 0;
    if (exists(base ~ path)) {
      if (isDir(base ~ path)) {
        return 1;
      } else {
        return 2;
      }
    } else {
      return 0;
    }
  }

  /** 从元数据中解析出逻辑路径对应的真实文件名。

      当未配置 `metaDao` 时返回空字符串。
  */
  public string getRealname(const(BlobProfile) profile, string path) {
    if (metaDao !is null) {
      return metaDao.getFilename(profile, path);
    } else {
      return "";
    }
  }

  static BlobRepo build(MicdnConfig config,MetaDao metaDao) {
    return new BlobRepo(config.blob.base, config.blob.publicList, config.blob.maxSize,
    config.blob.profiles, config.blob.keys, metaDao);
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
  public BlobMeta create(const(BlobProfile) profile, string tmpfile, string filename,
      string dir, string owner, string mediaType) {
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
    meta.filePath = filePath[profile.base.length .. $];
    mkdirRecurse(dirName(this.base ~ profile.base ~ meta.filePath));
    copy(tmpfile, this.base ~ profile.base ~ meta.filePath);
    if (metaDao !is null) {
      metaDao.remove(profile, meta.filePath);
      metaDao.create(profile, meta);
    }
    return meta;
  }

  /** 删除仓库中的物理文件及其元数据。

      Params:
          profile = 所属 profile
          path    = 相对于仓库根目录的完整路径（包含 profile.base）

      Returns:
          true  = 文件存在并已删除
          false = 文件不存在
  */
  public bool remove(const(BlobProfile) profile, string path) {
    if (std.file.exists(this.base ~ path)) {
      std.file.remove(this.base ~ path);
      if (metaDao !is null) {
        metaDao.remove(profile, path[profile.base.length .. $]);
      }
      return true;
    } else {
      return false;
    }
  }

  const(BlobProfile) getProfile(string path) const {
    foreach (k, v; profiles) {
      if (path.startsWith(k)) {
        return v;
      }
    }
    return defaultProfile;
  }

}
