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
/// 基于 dxml DOM 的通用 XML 解析辅助函数；micdn.xml 不支持 `<xi:include>`。

import std.algorithm;
import std.file;
import std.format;
import std.path;
import std.string;

import dxml.dom;
import dxml.parser : EntityType, TextPos, XMLParsingException;
import dxml.util : decodeXML;

/** micdn.xml 解析或结构校验失败；`msg` 已含文件路径、行列与上下文，可直接打印给用户。 */
class MicdnXmlException : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
    super(msg, file, line);
  }
}

auto getAttrs(T)(ref DOMEntity!T dom) {
  string[string] a;
  foreach (at; dom.attributes) {
    a[at.name] = decodeXML(at.value).idup;
  }
  return a;
}

/** 元素直属文本（含 CDATA）；普通文本按 XML 实体规则解码，CDATA 保持原样。 */
string elementText(T)(ref DOMEntity!T dom) {
  import std.array : appender;

  auto app = appender!string();
  foreach (c; dom.children) {
    switch (c.type) {
    case EntityType.text:
      app.put(decodeXML(c.text));
      break;
    case EntityType.cdata:
      app.put(c.text);
      break;
    default:
      break;
    }
  }
  return app.data.strip;
}

bool isNamedElement(EntityType t) @safe pure nothrow @nogc {
  return t == EntityType.elementStart || t == EntityType.elementEmpty;
}

auto children(T)(ref DOMEntity!T dom, string path) {
  return dom.children.filter!(c => isNamedElement(c.type) && c.name == path);
}

/** 解析 XML 为根元素；`sourceFile` 非空时写入友好错误信息。 */
DOMEntity!R parseDomRoot(R)(R content, const string sourceFile = null) {
  try {
    auto dom = parseDOM!simpleXML(content);
    if (dom.children.length == 0)
      throw new MicdnXmlException(xmlErrorPrefix(sourceFile) ~ "document is empty");
    return dom.children[0];
  } catch (MicdnXmlException e) {
    throw e;
  } catch (XMLParsingException e) {
    throw new MicdnXmlException(formatXmlParseError(sourceFile, content, e));
  }
}

/** 拒绝元素内非空白文本（如误写的 `-`、残留字符），避免后续访问 `.name` 触发断言。 */
void checkNoStrayText(T)(ref DOMEntity!T dom, const string sourceFile, const string content) {
  foreach (c; dom.children) {
    if (c.type == EntityType.text) {
      auto t = c.text.strip();
      if (t.length > 0)
        throw strayTextException(sourceFile, content, c.pos, t);
    } else if (c.type == EntityType.elementStart) {
      checkNoStrayText(c, sourceFile, content);
    }
  }
}

/** 读取本地 XML（支持 `~`），不展开任何 include。 */
string readXml(const string xmlfile) {
  string p = expandTilde(xmlfile);
  if (!exists(p))
    throw new MicdnXmlException(xmlfile ~ " does not exist");
  string abs = absolutePath(p);
  return cast(string) read(abs);
}

auto parseXml(string xml) {
  return parseDomRoot(xml);
}

private string xmlErrorPrefix(const string sourceFile) {
  return sourceFile.length > 0 ? sourceFile ~ ": " : "";
}

private string formatXmlParseError(const string sourceFile, const string content, XMLParsingException e) {
  string snippet = xmlLineAt(content, e.pos.line);
  string near = snippet.length > 0 ? format("\n  near: %s", snippet) : "";
  return xmlErrorPrefix(sourceFile) ~ e.msg ~ near;
}

private MicdnXmlException strayTextException(const string sourceFile, const string content,
    const TextPos pos, const string text) {
  string preview = text.length > 40 ? text[0 .. 40] ~ "…" : text;
  string snippet = xmlLineAt(content, pos.line);
  string near = snippet.length > 0 ? format("\n  near: %s", snippet) : "";
  return new MicdnXmlException(format("%sunexpected text outside tags at line %s, column %s: %r%s",
      xmlErrorPrefix(sourceFile), pos.line, pos.col, preview, near));
}

private string xmlLineAt(const string content, int line) {
  if (line < 1 || content.length == 0)
    return "";
  int cur = 1;
  size_t i = 0;
  while (i < content.length && cur < line) {
    if (content[i] == '\n')
      cur++;
    i++;
  }
  if (cur != line)
    return "";
  size_t j = i;
  while (j < content.length && content[j] != '\n' && content[j] != '\r')
    j++;
  return content[i .. j];
}
