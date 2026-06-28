# Micdn v0.2.6 Release Notes

**发布日期：** 2026-06-28  
**对比基线：** [v0.2.5](https://github.com/beangle/micdn/compare/v0.2.5...v0.2.6)

---

## 概要

v0.2.6 将部署前 **`validate` 升级为 `resolve`**（自动下载并 mount www/static），整理 admin 指标模块与 metrics 仪表盘模板，并升级 vibe 栈依赖。

**无 `micdn.xml` 配置格式 Breaking Change**（与 v0.2.5 兼容）。

---

## 亮点总结

| 类别 | 改进 |
|------|------|
| **CLI** | `micdn -f CONFIG resolve` 替代 `validate`，全量安装 www/static |
| **运维** | `metrics.d` 合并 idle GC / memstats；HTML 仪表盘迁至 `views/metrics.dt` |
| **内存** | idle GC 去掉 15 分钟冷却，检查 tick 满足条件即 `GC.minimize` |
| **依赖** | vibe-http 1.5.1、vibe-inet 1.3.1、vibe-stream 1.4.1 |

---

## CLI：`resolve`（替代 `validate`）

```bash
micdn -f /etc/micdn/micdn.xml resolve
```

- 解析配置与 `listen`，检查各服务数据根目录可写
- 下载缺失 jar/npm、解压 zip/tgz，mount 全部 www/static，校验 zip/npm **inner `dir`**
- 不启动 HTTP；成功 `resolve ok: …`（退出码 0）

说明见 [maintenance.md](./maintenance.md)。

---

## Admin 指标整理

- `idle_gc.d`、`memstats.d` 合并进 **`micdn.admin.metrics`**
- `/admin/metrics` 使用 **diet-ng** 模板 **`views/metrics.dt`**（与目录列表 `index.dt` 一致）
- `rssKb` / `hwmKb` / `gcUsed` / `gcFree` 字段注释补充

---

## 依赖升级

| 包 | v0.2.5 | v0.2.6 |
|----|--------|--------|
| vibe-http | 1.3.3 | **1.5.1** |
| vibe-inet | 1.2.0 | **1.3.1** |
| vibe-stream | 1.3.0 | **1.4.1** |
| vibe-serialization | 1.0.7 | **1.2.0** |
| vibe-d:web | 0.10.3 | 0.10.3 |
| dxml | 0.4.5 | 0.4.5 |

`vibe-stream:tls` 仍为 **`notls`**。

---

## 升级注意

1. 脚本与文档中的 **`validate` 改为 `resolve`**
2. 升级后建议执行：
   ```bash
   micdn -f /etc/micdn/micdn.xml resolve
   systemctl restart micdn
   ```
3. 生产构建请继续使用 **`dub build --build=release-nobounds --compiler=ldc2`** + **`strip`**（与 `build_rpm.sh` 一致）

---

## 测试

89 个单元测试通过（含 `resolve_test.d`、`metrics_test.d`）。
