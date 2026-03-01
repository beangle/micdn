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

module micdn.xml;
/// 基于 dxml DOM 的通用 XML 解析辅助函数集合。

import std.algorithm;
import std.file : exists, read;
import std.path : expandTilde;

import dxml.dom;

auto getAttrs(T)(ref DOMEntity!T dom) {
  string[string] a;
  foreach (at; dom.attributes) {
    a[at.name] = at.value;
  }
  return a;
}

auto children(T)(ref DOMEntity!T dom, string path) {
  return dom.children.filter!(c => c.name == path);
}

string readXml(string xmlfile) {
  auto fullPath = expandTilde(xmlfile);
  if (exists(fullPath)) {
    return cast(string) read(fullPath);
  } else {
    throw new Exception(xmlfile ~ " is not exists!");
  }
}

auto parseXml(string xml) {
  return parseDOM(xml).children[0];
}
