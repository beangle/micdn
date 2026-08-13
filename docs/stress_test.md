# micdn 压测复测指南

本文用于**复现并比较** [docs/stress_report.md](./stress_report.md) 的压测基线：覆盖最坏路径（目录 → `index.html`，5 次 stat）、文件命中、404 与 gzip 命中四个场景。所有命令面向 Linux + `ab`（ApacheBench）。

---

## 1. 环境记录（每次复测更新）

| 项目 | 记录项 |
|------|--------|
| 日期 | 复测日期 |
| 操作系统 | `uname -a` |
| CPU | `lscpu`（型号、核数、当前频率） |
| 内存 | `free -h` |
| micdn 版本/commit | `git rev-parse HEAD`（报告用短 hash） |
| 构建 | `dub build --build=release-nobounds --compiler=ldc2` |
| ab 版本 | `ab -V` |
| 机器负载 | 压测前后 `uptime`（load average） |

2026-08-13 基线：Linux fc44 x86_64 · AMD Ryzen 7 7735HS（8C16T）· 59G · micdn 0.3.0（commit `490a455`）· ab 2.3 · 无后台负载 · 各场景预热 5 次后 3 轮取中位。
2026-08-13 复测：同机 · micdn 0.3.0（commit `8ddfd47`）· ab 2.3 · 无后台负载（load 0.53/0.40/0.40，CPU scaling 37%）· 同方法（预热 5 次 + 3 轮取中位）。
2026-08-13 索引版：同机 · micdn 0.3.0（commit `8ddfd47` + 发布期文件索引，未提交）· ab 2.3 · 无后台负载 · 同方法。
2026-08-13 提交前复测：同机 · 索引版（本提交）· ab 2.3 · `performance` 调速器（负载核 ~4.4 GHz）· 无后台负载 · 同方法。

> 同机多次运行也会有波动（实测预热后 3 轮：最坏路径 16.0k–20.7k RPS，CPU 频率 scaling 与页面缓存冷热所致）。比较时应记录负载与频率，按「预热 + 多轮取中位」执行，不要单次定论。

## 2. 构建

```bash
cd /path/to/micdn
dub build --build=release-nobounds --compiler=ldc2
git rev-parse HEAD        # 记录被测 commit
```

## 3. 准备样例（一次性）

生成 `/tmp/micdn-stress`：示例 www 内容（zip 部署）、micdn 配置。样例文件大小参考真实静态资源：`app.js` 约 138KB、`app.css` 44KB、`vendor.css` 14KB、`index.html` 174B、`docs/guide.html`。

```bash
set -e
D=/tmp/micdn-stress
rm -rf "$D"; mkdir -p "$D/src/dist/docs"

cat > "$D/src/dist/index.html" <<'EOF'
<!doctype html><html><head><title>manual</title>
<link rel="stylesheet" href="app.css"></head>
<body><h1>micdn stress manual</h1><script src="app.js"></script></body></html>
EOF

python3 - <<'PY'
import random
random.seed(42)
def gen(path, lines, width):
    with open(path,"w") as f:
        for i in range(lines):
            k = random.randrange(20)
            v = random.getrandbits(32)
            f.write("var k%02d = %d; /* %s */\n" % (k, v, "x"*width))
gen("/tmp/micdn-stress/src/dist/app.js", 1400, 70)
gen("/tmp/micdn-stress/src/dist/app.css", 500, 60)
gen("/tmp/micdn-stress/src/dist/vendor.css", 160, 60)
PY

cat > "$D/src/dist/docs/guide.html" <<'EOF'
<!doctype html><html><head><title>guide</title></head><body><p>guide page</p></body></html>
EOF

(cd "$D/src" && zip -qr "$D/manual.zip" dist)

cat > "$D/micdn.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<micdn home="/tmp/micdn-stress/home" listen="127.0.0.1:8899">
  <www base="/tmp/micdn-stress/www">
    <doc name="manual" zip="/tmp/micdn-stress/manual.zip" inner="dist" try-file="index.html" />
  </www>
</micdn>
EOF
```

> **坑**：样例内容不要用高度重复的文本（如纯 `console.log(...)` 循环），zip 压缩比超过 `maxZipCompressionRatio=100` 会被 micdn 按 zip 炸弹拒绝（日志 `compression ratio is too high`，导致 doc 未部署）。上面用随机数字 + 定长注释控制压缩比。

## 4. 启动与停止

```bash
# 前台（推荐，便于观察日志与 Ctrl-C 停止）
/path/to/micdn/target/micdn -f /tmp/micdn-stress/micdn.xml

# 或后台
nohup /path/to/micdn/target/micdn -f /tmp/micdn-stress/micdn.xml > /tmp/micdn-stress/micdn.log 2>&1 &
kill <pid>          # 停止
```

启动成功的标志：日志出现 `Listening for requests on http://127.0.0.1:8899/`。

## 5. 场景与压测命令（并发 100 × 10000）

建议每场景**预热 5 次**后跑 **3 轮**、取中位数（`docs/stress_report.md` 基线即按此方法）。预热指令见本节末。

依赖 `ab`：`sudo dnf install httpd-tools`（Debian 系为 `apache2-utils`）。

| 场景 | URL | 命令 | 预期 stat 次数 |
|------|-----|------|----------------|
| 最坏路径（目录 → index.html） | `/manual/` | `./scripts/stress_http.sh 'http://127.0.0.1:8899/manual/'` | 0（索引：目录折叠 index.html 查表） |
| 文件命中 | `/manual/app.js` | `./scripts/stress_http.sh 'http://127.0.0.1:8899/manual/app.js'` | 0（索引命中） |
| 404 未命中 | `/manual/nope.js` | `ab -r -n 10000 -c 100 'http://127.0.0.1:8899/manual/nope.js'` | 0（索引断链，静态资产不回退） |
| gzip 命中 | `/manual/app.js` | 先预热（见下），再 `ab -k -r -n 10000 -c 100 -H 'Accept-Encoding: gzip' 'http://127.0.0.1:8899/manual/app.js'` | 1（get 源文件 0 + sendFile 单次 `getFileInfo(gz)`） |

> 索引版（发布期文件索引）：`WwwRepo.build` 在 deploy 后遍历 docDir 构建段树索引（`IndexedFileInfo` 轻量快照），请求期存在性/目录折叠/try-file 回退全部查表（0 stat）；autodeploy 重新部署后 `WwwService.invalidateDoc` 触发重建。索引构建跳过 `*.gz`（运行期 sidecar，非部署内容；gz 服务由请求线程直接 `getFileInfo` 现查），反复启停不会把遗留 gz 的元数据预扫进 page cache。非 `build()` 构造的仓库（如直接 `new WwwRepo`）仍走 stat 路径。

**gzip 场景必须预热**：sidecar 由后台线程按需生成，首次请求只会入队并返回原版。

```bash
curl -s -H 'Accept-Encoding: gzip' -o /dev/null http://127.0.0.1:8899/manual/app.js
sleep 1                     # 等后台 worker 生成 app.js.gz
ls -l /tmp/micdn-stress/www/manual/app.js.gz
```

**单次压缩正确性验证**（回归检查）：

```bash
curl -s -H 'Accept-Encoding: gzip' http://127.0.0.1:8899/manual/app.js -o /tmp/got.gz
curl -sI -H 'Accept-Encoding: gzip' http://127.0.0.1:8899/manual/app.js   # 应见 Content-Length，无 Transfer-Encoding: chunked
zcat /tmp/got.gz | cmp - /tmp/micdn-stress/www/manual/app.js              # 单次解压 == 原始文件
```

> **404 不要用 `-k`**：`ab -k` 对非 2xx 响应会计为 Length 失败并断开连接，数字虚高且服务端刷屏 `Connection closed while writing data` 错误日志（客户端主动断开所致，非服务异常）。

> **跨场景比较口径**：各场景命令不同（keep-alive / 无 keep-alive），绝对 QPS 不可跨场景直接比较——实测同机同频率下，html 与 404 用相同无 `-k` 命令时吞吐几乎相等，报告中的差距主要来自命令口径而非服务行为。对比时应：同场景复测用相同命令；跨场景只比相对提升（如 stat 次数下降带来的增幅），不比绝对数字；同时记录 CPU 频率（`scaling_cur_freq`），频率不同时数值不可比。

## 6. 结果记录模板

输出保存为 `/tmp/stress-<场景>.txt`，记录关键字段：

| 场景 | RPS | 平均延迟(ms) | P99(ms) | 失败 | 备注 |
|------|-----|-------------|---------|------|------|
| `/manual/` 最坏路径 |  |  |  |  | keep-alive |
| `/manual/app.js` 文件命中 |  |  |  |  | 约 1.2 GB/s（基线） |
| `/manual/nope.js` 404 |  |  |  |  | 不带 keep-alive |
| `/manual/app.js` gzip 命中 |  |  |  |  | 预热后 |

ab 摘要关键行：`Requests per second`、`Time per request (mean)`、`Percentage of the requests served`（P99）、`Failed requests`、`Transfer rate`。

## 7. 复测与比较要点

- **同环境**：比较 RPS/延迟/P99，多轮取中位数；记录 `uptime` 与 CPU 频率。
- **跨环境/版本**：先记录第 1 节环境表；代码改动后重跑四个场景，与基线表逐行对比。
- 最坏路径的 stat 次数取决于 `WwwRepo.get`（`src/micdn/www/package.d`）与 `sendFileImpl`（`src/micdn/web/file.d`）的实现，代码重构后按第 5 节表格核对预期值是否变化。
- 对比不同 commit 的结果时，记录被测 commit（第 1 节环境表）。

## 相关

- [docs/stress_report.md](./stress_report.md)：2026-08-13 基线报告
- [scripts/stress_http.sh](../scripts/stress_http.sh)：`ab` 包装脚本
