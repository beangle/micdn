module beangle.xml.reader;

import dxml.dom;

auto getAttrs(T)(ref DOMEntity!T dom){
  string[string] a;
  foreach (at;dom.attributes){
    a[at.name]=at.value;
  }
  return a;
}

auto children(T)(ref DOMEntity!T dom,string path){
  import std.algorithm;
  return dom.children.filter!(c => c.name==path);
}

