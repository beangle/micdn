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
  auto config = new BlobConfig("/blob", "~/tmp");
  MetaDao dao;
  if ("password" in props) {
    dao = new MetaDao(props, config);
  }
  if (dao !is null) {
    auto profile = new BlobProfile(1, "", null, false, false, 0, "");
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
