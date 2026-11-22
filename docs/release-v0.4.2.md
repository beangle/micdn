# Micdn v0.4.2 Release Notes

**发布日期：** 待定
**对比基线：** [v0.4.1](https://github.com/beangle/micdn/compare/v0.4.1...v0.4.2)

---

## 概要

v0.4.2 增加**仓库清理**与**上游 Bearer 令牌**，面向“中心 micdn 保存开发版、客户 micdn 按需代理”的部署方式。

- **清理**：npm 开发版与 maven SNAPSHOT 构建默认各保留 1 份；可手动执行，也可按 `<prune>` 每日自动执行。
- **令牌**：`<dev>` / `<snapshot>` 上游可配置 Bearer token，客户 micdn 从中心 micdn 下载时携带中心
  `<auth download-key>`。
- **仓库代理**：native 可按完整路径从中心 micdn 回源；SNAPSHOT 上传后自动生成版本级
  `maven-metadata.xml`，prune 删除旧构建后重写。
- **远程配置所有权**：micdn 不再持有控制台 token、不再自己下载 `micdn.xml`；basagent 拉取后
  投递给 localhost `/admin/config`，micdn 自己校验、原子落盘并 reload。`micdn.env` 已移除。
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

## 仓库代理与 SNAPSHOT 元数据

### Maven SNAPSHOT metadata

`PUT /maven/.../*-SNAPSHOT/带时间戳构件` 落盘后，micdn 扫描版本目录并生成/刷新：

```text
maven-metadata.xml
maven-metadata.xml.sha1
```

因此只上传时间戳 war/jar + `.sha1` 的客户端（如 `SnapshotPlugin`、`snapshot-upload`）不再需要
自行生成 metadata；`mvn deploy` 主动上传的 metadata 会保留，直到 prune 重写。

`pruneSnapshotBuilds` 删除旧构建后按剩余文件重写版本级 metadata，避免 `<snapshotVersions>` 指向
已删除文件；即使本次没有删除，也会补齐缺失的 metadata。已有旧构件需要重新上传一次或执行一次
`micdn prune` 才会补上 metadata。

### `~` 路径

`home` 和各仓库 `base` 中的裸 `~` / `~/...` 统一按当前进程用户的 passwd home 展开，不依赖
systemd 的 `$HOME`；因此可以写：

```xml
<micdn home="~">
  <maven base="~/maven"/>
```

`home="~"` 与 `base="~/maven"` 会落到同一个目录。若节点使用非默认安装路径，仍应显式写绝对
路径的 `home`。

### Native 上游

```xml
<native base="/var/lib/micdn/native">
  <remote url="http://central-micdn:8888/native" token="<central-download-key>"/>
</native>
```

本地有文件时直接发本地；缺失时按完整路径回源并缓存，目录列表仍来自本地。未配置 `<remote>` 时
缺失仍为 404。

## 远程配置与权限

- 删除 `/etc/micdn/micdn.env`；micdn 不再读取 `BAS_PRINCIPAL` / `BAS_TOKEN`。
- basagent 的 `micdn:reload` 拉取 `GET /api/bashub/micdn/{project}/micdn.xml`，再 POST 到
  `127.0.0.1:8888/admin/config`；micdn 完整校验，成功后原子写入自己的
  `micdn.xml` 并重建 router。
- `/admin/config` 只接受 localhost，body 上限 4 MiB；失败时旧文件和旧 router 都不变。
- `micdn.xml` 不再支持 `xi:include`：配置必须是一份完整文件，解析器遇到 `<xi:include>` 直接报错。
- 包安装把 `/etc/micdn` 设为 `micdn:beangle 0750`，`micdn.xml` 为 `micdn:beangle 0640`；
  basagent 不需要写权限。
- micdn 启动必须有本地 `micdn.xml`；包默认配置可保证首次启动。

## 日志

安装包默认配置将业务日志写到 `/var/log/micdn/micdn.log`，并新增
`/etc/logrotate.d/micdn`：

- 每日轮转，保留 14 份；
- `copytruncate`，无需重启 micdn；
- `su micdn beangle`，与运行账号一致。

启动/配置错误仍输出到 stderr，由 systemd 收进 journal；业务日志看文件。

## 升级

1. 旧配置可直接启动；不写 `<prune>` 不会自动删除任何文件。
2. 需要自动清理时增加 `<prune>`，先用 `micdn prune ... --dry-run` 核对数量。
3. 需要从中心代理 dev/SNAPSHOT 时，给 `<dev>` / `<snapshot>` 配 token；中心对应开启
   `<auth download-key>`。
4. 远程配置由 basagent 拉取并投递；需要 **basagent/basctl 0.0.3** 及以上，删除 `micdn.env`，
   确认 `/etc/micdn` 权限。
5. 旧 SNAPSHOT 构件缺少 metadata 时，重新上传一次或执行 `micdn prune` 补生成。
6. 需要从中心代理 native 时，给 `<native>` 增加 `<remote>`；中心开启 `<auth download-key>`。
7. 配置改动后执行 `micdn` reload（或重启）；清理器按新配置重建。

## 测试

`dub test --compiler=ldc2`：**229 passed, 0 failed**。

> 安装包与容器镜像版本从 git tag 推导；发布 0.4.2 前需创建并推送 `v0.4.2` tag。
