# Micdn v0.4.2 Release Notes

**发布日期：** 2026-11-18
**对比基线：** [v0.4.1](https://github.com/beangle/micdn/compare/v0.4.1...v0.4.2)

---

## 概要

v0.4.2 增加**仓库清理**与**上游 Bearer 令牌**，面向“中心 micdn 保存开发版、客户 micdn 按需代理”的部署方式。

- **清理**：npm 开发版与 maven SNAPSHOT 构建默认各保留 1 份；可手动执行，也可按 `<prune>` 每日自动执行。
- **令牌**：`<dev>` / `<snapshot>` 上游可配置 Bearer token，客户 micdn 从中心 micdn 下载时携带中心
  `<auth download-key>`。
- **不改变正式版语义**：正式版 remote、`<micdn remote>`（v0.4.1 已移除）和现有配置都不受影响。

## 仓库清理

新增配置：

```xml
<prune at="03:30" npm-dev-keep="1" maven-snapshot-keep="1"/>
```

- `at` 是本机时区 `HH:MM`，默认 `03:30`；每个 micdn 自己调度，不依赖 bashub/basagent。
- 不写 `<prune>` 时不调度，只保留手动入口。
- `npm-dev-keep` / `maven-snapshot-keep` 至少为 1。

npm 规则（`pruneDevVersions`）：

- 每个包只保留最新 `npm-dev-keep` 个预发布版本；
- 正式版、`dist-tags` 指向的版本一律保留；
- 只处理本地有版本目录和 tgz 的条目，上游代理来的 packument 条目不删除；
- 先重写 packument，再删除版本目录；写失败不会留下悬空元数据。

maven 规则（`pruneSnapshotBuilds`）：

- 每个 `*-SNAPSHOT` 版本目录保留最新 `maven-snapshot-keep` 个时间戳构建；
- 版本级 `maven-metadata.xml` 指向的构建额外保留；
- artifact 级元数据不动；jar/pom 及配套 `.sha1` 一起删除。

手动入口：

```bash
micdn -f /etc/micdn/micdn.xml prune npm --keep-dev=1 --dry-run
micdn -f /etc/micdn/micdn.xml prune maven --keep-builds=1
micdn -f /etc/micdn/micdn.xml prune all
```

`GET /admin/prune` 仅允许本机回环访问，返回本次统计；不提供远程触发。

## 上游令牌

```xml
<npm base="/var/lib/micdn/npm">
  <dev remote="http://central-micdn:8888/npm" token="<central-download-key>"/>
</npm>
<maven base="/var/lib/micdn/maven">
  <snapshot remote="http://central-micdn:8888/maven" token="<central-download-key>"/>
</maven>
```

- token 以 `Authorization: Bearer` 发送，只作用于 `<dev>` / `<snapshot>` 上游；正式版 `<remote>` 保持匿名。
- 未配置 token 时匿名回源；中心开启 `<auth download-key>` 而客户未配置时返回 401。
- 令牌只应指向中心 micdn 或会补同值鉴权的反代；不要把外部 registry 配成 dev/snapshot 上游并附带中心令牌。
- bashub 侧由 `<snapshot download-token>` 统一下发到 `<snapshot token>` 和 `<dev token>`。

## 升级

1. 旧配置可直接启动；不写 `<prune>` 不会自动删除任何文件。
2. 需要自动清理时增加 `<prune>`，先用 `micdn prune ... --dry-run` 核对数量。
3. 需要从中心代理 dev/SNAPSHOT 时，给 `<dev>` / `<snapshot>` 配 token；中心对应开启
   `<auth download-key>`。
4. 配置改动后执行 `micdn` reload（或重启）；清理器按新配置重建。

## 测试

`dub test --compiler=ldc2`：**236 passed, 0 failed**。

> 安装包与容器镜像版本从 git tag 推导；发布 0.4.2 前需创建并推送 `v0.4.2` tag。
