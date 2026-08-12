# micdn 与反向代理 / 上游中间件协作部署

micdn 是单进程、配置驱动的 HTTP 静态服务。生产环境常见在前置 nginx / varnish / haproxy，负责 **TLS 终止、共享缓存、压缩与负载均衡**。本文说明 micdn 与这些中间件的职责边界和协作注意事项。

---

## 职责边界：micdn 不做 HTTP 共享缓存

micdn **不维护响应级的共享缓存**：每个请求都直接读磁盘返回（或发送后台已生成的 `.gz`），只通过 `Cache-Control` / `ETag` / `Last-Modified` / `Vary` 头声明「可缓存性」与「内容变体」，由浏览器与上游缓存层执行。

因此：

- 需要**共享缓存**（多客户端复用、抗热点、降下游压力）时，在前面部署 nginx `proxy_cache` 或 varnish。
- micdn 已按内容类型设置恰当的缓存头，缓存层「按头执行」即可开箱工作：

| 内容 | `Cache-Control` | 说明 |
|------|-----------------|------|
| Maven/npm release 构件、static bundle、WebJar | `public, max-age=31536000, immutable` | 版本化/指纹资源，可长期缓存 |
| `maven-metadata.xml` | `public, no-cache` | 每次回源校验 |
| `SNAPSHOT`、`*.lastUpdated`、`resolver-status.properties` | `no-store` | 禁止缓存 |
| static `<dir>` dyna bundle | `public, no-cache` | 回源校验 |
| www 文档 `*.html` | `public, no-cache` | 回源校验 |
| www 其余静态文件 | `public, max-age=604800` | 7 天 |
| blob 对象 | `public, max-age=604800` | 7 天 |

- 可压缩内容统一带 `Vary: Accept-Encoding`（见 [README gzip 预压缩](../README.md)），缓存层会按 `Accept-Encoding` 分别缓存「原版」与「gz 版」，gzip 客户端命中压缩版、其余客户端命中原版，不会错发。
- 注意区分：maven/npm 的「本地缓存」是 micdn 把上游 remote 构件**落盘镜像**（避免重复回源下载），属于 micdn 内部行为，与 HTTP 响应缓存是两回事；后者才需要中间件。

---

## 推荐拓扑

```
客户端
  → 反向代理（nginx / varnish / haproxy：TLS、共享缓存、压缩）
      → micdn（默认监听 127.0.0.1:8888，`<micdn listen="127.0.0.1:8888">` 可改）
```

- micdn 默认只监听 `127.0.0.1`，反向代理与 micdn 同机部署即可，公网只暴露代理。
- `/admin` 与业务端口同 listener，反代时在代理层拒绝 `/admin`（或限 IP），避免管理端点暴露。
- micdn 不消费 `X-Forwarded-For`，其日志中的客户端地址为代理地址；需要真实 IP 时在代理日志侧处理。

---

## nginx：TLS 终止 + 共享缓存

```nginx
proxy_cache_path /var/cache/nginx/micdn levels=1:2 keys_zone=micdn:64m max_size=10g inactive=60m use_temp_path=off;

server {
  listen 443 ssl;
  server_name cdn.example.com;
  ssl_certificate     /etc/nginx/tls/fullchain.pem;
  ssl_certificate_key /etc/nginx/tls/privkey.pem;

  location = /admin { return 404; }

  location / {
    proxy_cache micdn;          # 缓存行为由上游 Cache-Control / Vary 决定
    proxy_pass http://127.0.0.1:8888;
  }
}
```

要点：

- micdn 每个响应都带显式 `Cache-Control`，一般**不需要** `proxy_cache_valid` 兜底。
- nginx `proxy_cache` 尊重 `Vary`，自动按 `Accept-Encoding` 分缓存条目；保持默认 `proxy_cache_key` 即可。

---

## varnish

- varnish 原生把 `Vary` 纳入缓存键，行为最贴合 micdn 的响应头。
- backend 指向 micdn；静态服务无 cookie，建议在 `vcl_recv` 中 `unset req.http.cookie` 提升命中率。

```vcl
backend micdn { .host = "127.0.0.1"; .port = "8888"; }

sub vcl_recv {
  unset req.http.cookie;
}
```

---

## haproxy：TLS / 压缩 / 负载均衡

micdn 已内置 sidecar 预压缩，haproxy 负责 TLS 终止、负载均衡与可选的「动态兜底压缩」：

```haproxy
frontend fe_cdn
  bind *:443 ssl crt /etc/haproxy/tls/cdn.pem
  compression algo gzip
  compression type text/html text/css text/plain text/xml application/json application/javascript application/xml+rss application/vnd.api+json
  default_backend be_micdn

backend be_micdn
  server micdn1 127.0.0.1:8888 check
```

### 与 micdn gzip 的关系

- **不冲突、不双重压缩**：haproxy 只对**没有** `Content-Encoding` 的响应做压缩；micdn 发送 gz 时已带 `Content-Encoding: gzip`，haproxy 直接跳过；micdn 返回原版的文本响应才可能被 haproxy 动态压缩。
- micdn 白名单（`js`/`css`/`html`/`svg`/`json`/`xml`/`txt`/`map` 等）已由 sidecar 预压缩；haproxy 的 `compression type` 相当于为其余文本类型（如 `text/plain` 的 `*.properties`）提供动态兜底。
- 双方都会在可压缩响应上带 `Vary: Accept-Encoding`，浏览器与支持 `Vary` 的缓存按头分流。
- **不要开启 `compression offload`**：它会剥掉发往后端请求的 `Accept-Encoding`，micdn 的 `acceptsGzip()` 判定失效，sidecar gzip 永远不会被触发（全部退回原版），与动态压缩的配合也被破坏。
- 保留 micdn sidecar 而非由 haproxy 统一压缩：sidecar 每个文件只后台压缩一次，haproxy 动态压缩每个请求都重复执行（CPU 开销）。两者并存没有正确性问题。

### 若使用 haproxy 自带 cache

- haproxy 的 cache 模块缓存键**不含 `Vary`**（不区分 `Accept-Encoding` 变体），会把首个变体发给所有客户端——对可压缩内容会导致 gzip 客户端命中原版（或相反）。
- 需要按变体缓存的共享缓存请用 nginx `proxy_cache` 或 varnish；haproxy 保持只做 TLS / 压缩 / 负载均衡。
