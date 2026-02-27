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
