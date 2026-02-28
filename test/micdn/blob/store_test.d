module test.micdn.blob.store_test;

import micdn.blob.store;
import std.datetime.systime;
import std.stdio;
import micdn.model;

@("blob db meta dao smoke")
unittest {
  /*import dpq2.conv.to_d_types;
  toValue(Clock.currTime());*/

  string[string] props;
  props["serverName"] = "localhost";
  props["databaseName"] = "platform";
  props["user"] = "openurp";
  props["schema"] = "blb";
  //props["password"]="openurp";
  auto config = new BlobConfig("local.openurp.net", "~/tmp");
  MetaDao dao;
  if ("password" in props) {
    dao = new MetaDao(props, config);
  }
  if (dao !is null) {
    auto profile = new BlobProfile(1, "", null, false, false);
    dao.remove(profile, "/a");
    BlobMeta meta = new BlobMeta();
    meta.profileId = profile.id;
    meta.owner = "me";
    meta.name = "a.txt";
    meta.fileSize = 3;
    meta.mediaType = "text/plain";
    meta.sha = "aa";
    meta.filePath = "/a.txt";
    meta.updatedAt = Clock.currTime();
    dao.remove(profile, "/a.txt");
    assert(dao.create(profile, meta));
  }
}
