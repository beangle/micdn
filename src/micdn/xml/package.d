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
/// 基于 dxml DOM 的通用 XML 解析辅助函数；`readXml` 会展开 `<xi:include href="..."/>`（双引号）后再返回文本。

import std.algorithm;
import std.file;
import std.format;
import std.path;
import std.regex;
import std.string;

import micdn.fs.file : isPathUnder;

import dxml.dom;
import dxml.parser : EntityType, TextPos, XMLParsingException;

/** micdn.xml 解析或结构校验失败；`msg` 已含文件路径、行列与上下文，可直接打印给用户。 */
class MicdnXmlException : Exception {
  this(string msg, string file = __FILE__, size_t line = __LINE__) @safe {
    super(msg, file, line);
  }
}

auto getAttrs(T)(ref DOMEntity!T dom) {
  string[string] a;
  foreach (at; dom.attributes) {
    a[at.name] = at.value;
  }
  return a;
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

/** 读取本地 XML（支持 `~`），展开全部自闭合 `<xi:include href="相对路径"/>` 后返回 UTF-8 字符串。
    `maven`/`npm`/`blob`/`static`/`www` 彼此无固定顺序要求；展开后由 `parse` 校验各服务元素至多出现一次。
    抛出：文件不存在，或 include 非法（`..`、绝对路径、路径逃出基准目录）。 */
string readXml(const string xmlfile) {
  string p = expandTilde(xmlfile);
  if (!exists(p))
    throw new MicdnXmlException(xmlfile ~ " does not exist");
  string abs = absolutePath(p);
  string content = cast(string) read(abs);
  return expandXiIncludes(dirName(abs), content);
}

/** 在 `baseDir` 下解析 `href`，将内容中的自闭合 `<xi:include .../>` 逐段替换为被包含文件正文（递归）。
    `baseDir` 建议为绝对路径目录（当前文件所在目录）。仅支持双引号 `href`。 */
string expandXiIncludes(const string baseDir, const string content) {
  auto re = regex(`<xi:include\s[^>]*href\s*=\s*"([^"]+)"[^>]*/\s*>`, "s");
  string absBase = absolutePath(baseDir);
  string cur = content;

  while (true) {
    auto m = matchFirst(cur, re);
    if (m.empty)
      break;
    string href = m[1];

    if (href.indexOf("..") >= 0)
      throw new MicdnXmlException(`xi:include: ".." is not allowed in href: ` ~ href);
    if (isAbsolute(href))
      throw new MicdnXmlException("xi:include: absolute href is not allowed: " ~ href);

    string incPath = absolutePath(buildNormalizedPath(absBase, href));
    if (!isPathUnder(absBase, incPath))
      throw new MicdnXmlException("xi:include: path escapes base directory: " ~ href);

    if (!exists(incPath))
      throw new MicdnXmlException("xi:include: file not found: " ~ incPath);

    string inc = stripXmlDeclaration(cast(string) read(incPath));
    inc = expandXiIncludes(dirName(incPath), inc);
    // replaceFirst 第三参数按正则替换格式解析：`$` / `${name}` 有特殊含义；被包含文件里
    // 若出现 `${micdn.home}` 等，`.` 会打断 `${...}` 解析而抛错，故先转义为字面 `$`。
    cur = replaceFirst(cur, re, escapeRegexReplacement(inc));
  }
  return cur;
}

private string escapeRegexReplacement(string s) {
  import std.string : replace;

  return replace(s, "$", "$$");
}

private string stripXmlDeclaration(const string s) {
  string t = s.strip();
  if (t.length >= 5 && t.startsWith("<?xml")) {
    size_t end = indexOf(t, "?>");
    if (end != size_t.max)
      return t[end + 2 .. $].strip();
  }
  return s;
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
