module micdn.blob.repository;
/// Blob 元数据与物理文件之间的仓库协调层。

import std.stdio;
import std.file;
import std.algorithm;
import std.string;
import std.conv;
import micdn.blob.db;
import micdn.blob.config;

/// 单个 Blob 仓库，负责在磁盘目录与数据库元数据之间做协调。
class Repository {
  /// 仓库根目录（实际文件存放的根路径，以 "/" 结尾）。
  const string base;
  /// 元数据访问对象，为空时仅使用文件系统，不记录数据库。
  MetaDao metaDao;
  /// 需要特殊处理为图片的扩展名集合。
  bool[string] images;

  /** 构造一个仓库。

      Params:
          b       = 仓库根目录（如 "/var/blob/"）
          metaDao = 元数据 DAO，可为空表示不持久化元数据
  */
  this(string b, MetaDao metaDao) {
    this.base = b;
    this.metaDao = metaDao;
    images[".jpg"] = true;
    images[".png"] = true;
    images[".gif"] = true;
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
  public string getRealname(const(Profile) profile, string path) {
    if (metaDao !is null) {
      return metaDao.getFilename(profile, path);
    } else {
      return "";
    }
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
  public BlobMeta create(const(Profile) profile, string tmpfile, string filename,
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
  public bool remove(const(Profile) profile, string path) {
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

}
