# Micdn v0.4.4 Release Notes

**发布日期：** 2026-11-27
**对比基线：** [v0.4.3](https://github.com/beangle/micdn/compare/v0.4.3...v0.4.4)

---

## 概要

v0.4.4 是一个 XML 解析与序列化修复版本。`dxml` 默认不会替换 XML 实体，v0.4.3 直接把解析器返回的
原始属性值用于配置，导致含 `&`、`<`、`>` 等字符的 bucket key、token、URL 和路径与配置文件中的
真实值不一致。

最直接的影响是 EMS Portal 应用文件下载：`micdn.xml` 中的 bucket key 含 `&amp;`、`&lt;`、`&gt;`
时，EMS 使用真实 key 生成 `?token=&t=`，micdn 却使用转义后的字面值校验，最终返回 401。

## 修复

### 配置属性实体解码

所有通过 `getAttrs` 读取的 XML 属性现在统一调用 `decodeXML`，覆盖：

- `&amp;`、`&lt;`、`&gt;`、`&quot;`、`&apos;`
- 十进制字符引用，如 `&#38;`
- 十六进制字符引用，如 `&#x3C;`

修复范围不只 bucket key，也包括 `<auth>` 的 publish/download key、上游 token、remote URL、
本地路径和其他 `<micdn>` 配置属性。

### Maven metadata 与 POM 文本节点

Maven `maven-metadata.xml` 和 `pom.xml` 的文本读取改用统一 `elementText`：

- 普通文本节点按 XML 规则解码实体；
- CDATA 保持原文，不做实体解码；
- `groupId`、`artifactId`、`version`、快照文件名等字段读取口径一致。

### 配置序列化

`toXml` 现在对所有属性值进行 XML 转义，不再只处理 bucket key。属性中的制表符、换行和回车分别写成
`&#9;`、`&#10;`、`&#13;`，避免 XML 属性空白归一化改变原值。`/admin/config.xml` 输出与配置文件
写回均可正确往返。

## 影响与兼容性

- 无配置格式变更，无 CLI 参数变更，无破坏性变更。
- 不需要轮换下载 key，也不需要修改 EMS 的 `conf.properties`。
- 升级后原有 `micdn.xml` 可继续使用；含特殊字符的属性会被正确解释。
- 使用含 `&` 的远端 URL、含特殊字符的本地路径或 token 的部署也会一并恢复正常。

## 升级

1. 安装 0.4.4 二进制或系统包；
2. 校验配置：

   ```sh
   micdn -f /etc/micdn/micdn.xml --check
   ```

3. 重启 micdn：

   ```sh
   sudo systemctl restart micdn
   ```

4. 确认版本与下载：

   ```sh
   micdn --version
   ```

然后从 EMS Portal 重新点击应用文件下载，确认 token 校验返回正常文件而不是 401。

## 测试

```text
dub test --compiler=ldc2：233 passed, 0 failed
dub build --build=release-nobounds --compiler=ldc2：成功
```

测试覆盖全部五种预定义 XML 实体、十进制/十六进制字符引用、CDATA、URL 查询参数以及属性空白字符
往返。

> 安装包与容器镜像版本从 git tag 推导；发布 0.4.4 前需创建并推送 `v0.4.4` tag。
