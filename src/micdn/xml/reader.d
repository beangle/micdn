module micdn.xml.reader;
/// 基于 dxml DOM 的通用 XML 解析辅助函数集合。

import dxml.dom;

auto getAttrs(T)(ref DOMEntity!T dom) {
  string[string] a;
  foreach (at; dom.attributes) {
    a[at.name] = at.value;
  }
  return a;
}

auto children(T)(ref DOMEntity!T dom, string path) {
  import std.algorithm;

  return dom.children.filter!(c => c.name == path);
}

import std.path : expandTilde;
import std.file : exists, read;

string readXml(string xmlfile) {
  auto fullPath = expandTilde(xmlfile);
  if (exists(fullPath)) {
    return cast(string) read(fullPath);
  } else {
    throw new Exception(xmlfile ~ " is not exists!");
  }
}
