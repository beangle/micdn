# micdn 日常维护（普通用户与权限）

本文面向通过 **deb/rpm** 安装、由 **systemd** 托管的部署（见 **[build_linux.md](./build_linux.md)**）。服务进程以 **`micdn`** 用户运行，属组为 **`beangle`**；数据与缓存目录对 **`beangle` 组可写**，便于**不必使用 root** 即可维护仓库数据、静态资源构建目录等。

---

## 服务身份与目录

| 项目 | 说明 |
|------|------|
| 运行用户 | `micdn`（系统用户，无登录 shell） |
| 运行组 | `beangle` |
| 配置文件 | `/etc/micdn/micdn.xml`（首次安装由 `/usr/share/micdn/micdn.xml.default` 复制） |
| 常见数据路径 | `/var/lib/micdn/`（blob、maven、npm、local 等）、`/var/cache/micdn/`（asset、www）、`/var/log/micdn/` |

安装脚本会将上述 **`/var/*`** 目录 **`chown` 为 `micdn:beangle`**，并设为 **`2775`**（`rwxrwsr-x`：组可读写、**setgid** 使新建子目录继承 **`beangle` 组**）。systemd 单元中配置了 **`UMask=0002`**，进程新建文件对组可写。

---

## 将维护账号加入 `beangle` 组

在维护机（例如你自己的登录用户 `alice`）上执行：

```bash
sudo usermod -aG beangle "$USER"
```

或使用：

```bash
sudo adduser "$USER" beangle
```

**重新登录**（或 `newgrp beangle`）后，`groups` 中应出现 `beangle`。此后你对 **`/var/cache/micdn`**、**`/var/lib/micdn`**、**`/var/log/micdn`** 下已有 **`beangle` 组权限** 的目录，可在不写 root 的前提下进行日常文件操作（上传 blob、整理缓存、查看日志等）。

---

## 为何需要组可写

- 进程以 **`micdn:beangle`** 创建文件；若只有 `micdn` 用户可写、组不可写，普通维护用户即使用户在 `beangle` 组内也无法修改数据。
- **`2775` + setgid** 保证在目录内新建子目录仍属 **`beangle` 组**，与 **`UMask=0002`** 一起，使同组维护人员能持续读写新产生的文件。

**若曾用 root 在数据目录下新建了文件/目录**，可能出现属主为 `root`、组不可写的情况，可修正为（示例）：

```bash
sudo chown -R micdn:beangle /var/cache/micdn /var/lib/micdn /var/log/micdn
sudo chmod 2775 /var/cache/micdn /var/cache/micdn/asset /var/cache/micdn/www
sudo chmod 2775 /var/lib/micdn /var/lib/micdn/blob /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local
sudo chmod 2775 /var/log/micdn
```

（与安装包 **postinst** 中逻辑一致；若目录结构有自定义子路径，对相应路径一并执行。）

---

## 编辑 `/etc/micdn/micdn.xml`

默认一般为 **`root:root`**、**`0644`**，普通用户**不能直接保存**。可选方式：

1. **sudo 编辑**（最常见）：

   ```bash
   sudo nano /etc/micdn/micdn.xml
   # 或
   sudo vim /etc/micdn/micdn.xml
   ```

2. **允许 `beangle` 组共同维护配置**（需管理员执行一次）：

   ```bash
   sudo chgrp beangle /etc/micdn/micdn.xml
   sudo chmod 664 /etc/micdn/micdn.xml
   ```

   加入 **`beangle`** 组的用户即可用编辑器直接保存（仍建议通过 **`sudo systemctl reload micdn`** 或 **SIGHUP** 按你环境要求重载配置）。
   **注意**：组可写会扩大能改配置的人的范围，请仅在可信管理员组内使用。

修改配置后若服务支持热加载，可 **`systemctl reload micdn`**（即 SIGHUP）；否则 **`systemctl restart micdn`**。reload 的触发方式、工作流程与生效边界见 **[reload.md](./reload.md)**。

---

## 解析配置（`resolve`）

在 **restart / reload 前**、CI 或首次部署时，解析配置并安装 www/static（**不启动 HTTP**）：

```bash
sudo -u micdn micdn -f /etc/micdn/micdn.xml resolve
```

### 两阶段

| 阶段 | 内容 | 失败时 |
|------|------|--------|
| **1. 配置** | `parseFile`：XSD、endpoint 冲突、doc/bundle 属性、try-file 路径等 | stderr `micdn: …`，退出码 **2** |
| **2. 部署** | `listen` 格式；maven/npm/static/www/blob **根目录可写**；下载缺失 jar/npm、解压 zip/tgz、deploy www/static；校验 zip/npm **inner `dir`** 与部署目录 | 日志 `Resolve … failed: …`，退出码 **1** |

还会检查：GAV 格式（`group:artifact:version`）、`<dir location>` 是否存在、本地 zip 是否合法、npm spec 是否合法。**`try-file` 缺失仅 WARN**，不导致失败。

成功时输出 `resolve ok: …`，退出码 **0**。

与 **`deploy`** 的分工：`resolve` 一次性处理配置中的全部 www doc 与 static bundle（等同 `deploy www` + `deploy static`，但不支持 `--force`）；`deploy www|static [NAME]` 可单独重装指定项并加 `--force`。二者日志固定输出到**控制台**（info），不读 `micdn.xml` 的 `log-file` / `log-level`。

---

## 离线部署静态资源（`deploy`）

```bash
sudo -u micdn micdn -f /etc/micdn/micdn.xml deploy www
sudo -u micdn micdn -f /etc/micdn/micdn.xml deploy static
sudo -u micdn micdn -f /etc/micdn/micdn.xml deploy www manual --force   # 强制重装
```

### zip doc 自动 deploy（`auto-deploy="true"`，Linux）

对 `<doc zip="..." auto-deploy="true">`，HTTP 服务运行期会 inotify 监听 zip 所在目录；源 zip 写入完成或替换后自动 deploy（manifest 未变则跳过解压）。仅 Linux；非 Linux 启动时打 WARN 并忽略。

```xml
<doc name="manual" zip="/var/lib/micdn/releases/manual.zip" inner="dist" auto-deploy="true" />
```

---

## 在配置中新增本地目录时

若在 **`micdn.xml`** 中为 `<dir location="...">` 等指定**新路径**（例如新的挂载点），需保证：

- 目录存在，且 **`micdn` 用户可写**，或
- 属主为 **`micdn:beangle`**，权限与父目录策略一致（例如 **`2775`**），便于进程与组内维护用户同时访问。

---

## 部署判定：只看 `manifest.json`

`asset` / `www` 的部署产物是**可再生成**的缓存。是否跳过解压**只比对 `manifest.json` 与部署源文件**（`inner` 路径、`size`、`mtime`、逻辑 `artifact`），**不检查部署目录里还剩多少文件**。这是有意的取值：判定就是读一次 manifest 加几个 `stat`，启动不会被大目录拖慢；代价是**产物被本进程之外的改动动过时不会自愈**——缺失的文件会一直 404，直到下一次强制部署。

> 曾评估在快路径里加“部署目录校验”（逐文件计数、目录指纹、目录 mtime）来自动重新部署。三种方案各有代价：计数发现不了“同目录新增 a、删除 b”；目录 mtime 会被本进程自己的写入（可写性探针、manifest）刷新，只有逐层重建目录状态才可靠，复杂度与启动成本都不划算。当前选择把 `manifest.json` 作为**唯一入口标准**，保持简单。

因此部署目录被外部清理或改坏后，不要指望重启自愈，直接强制重装对应的 bundle / doc：

```bash
sudo -u micdn micdn -f /etc/micdn/micdn.xml deploy static jquery --force
sudo -u micdn micdn -f /etc/micdn/micdn.xml deploy www manual --force
```

注意 `deploy` 之后，运行中实例的文件索引仍是启动 / reload 时建立的，需要 **重启或 `systemctl reload micdn`** 才会看到重新解压出来的内容（`reload` 见 [reload.md](./reload.md)）。

---

## 与容器部署的区别

**Podman/Docker** 镜像由 **`entrypoint`** 将数据目录 **`chown` 为 `micdn:beangle`**，见 **[container_build.md](./container_build.md)**。宿主机上的**组**与**权限**思路与上述一致：需要普通用户维护时，同样将用户加入 **`beangle`**，并保证挂载卷内权限与 **`micdn` 进程**一致。
