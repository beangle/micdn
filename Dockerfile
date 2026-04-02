# syntax=docker/dockerfile:1
# Multi-stage: debian:trixie-slim 自带 dub ≥1.34、ldc（与 trixie 仓库一致），glibc 与动态库 ABI 一致。
# 构建与运行阶段使用同一 Debian 基础镜像。
#
# 重复构建仍从网上拉 apt 包时，常见原因：
#   - 使用了 podman/docker build --pull / --pull-always（每次拉新基础镜像，整段缓存失效）
#   - 使用了 --no-cache
#   - 改了本 Dockerfile 里 apt 所在 RUN 之上的内容（含 FROM），或改了该 RUN 的包列表
# 下方 RUN 使用 BuildKit 的 apt 缓存挂载，层失效时仍尽量复用本机已下过的 deb。
# dub 依赖缓存在默认的 ~/.dub（builder 内为 /root/.dub）；对 dub build 挂载该目录以加速重复构建。
#
# Build: docker build -t micdn .
# Run:   docker run --rm -p 8888:8888 micdn
#        Optional persistence: -v micdn-cache:/var/cache/micdn -v micdn-data:/var/lib/micdn
#        进程以非 root 用户 micdn 运行（与 deploy/micdn.service 一致）。
#
# 若更倾向 Fedora，可将两阶段改为例如 fedora:42，并：dnf install -y ldc dub git ca-certificates curl unzip libpq-devel && dnf clean all
#
# 进一步缩小：ldc 静态链接 / distroless 等需单独评估；构建时可 docker build --squash（若引擎支持）。
#
# 国内加速 apt（可选，两阶段都要传；镜像地址可含 http 或 https）：
#   podman build --build-arg APT_MIRROR=https://mirrors.aliyun.com/debian \
#     --build-arg APT_SECURITY_MIRROR=https://mirrors.aliyun.com/debian-security -t micdn .
# 清华：APT_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian
#   APT_SECURITY_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/debian-security
#
# 若出现「SSL connection failed / certificate verify failed」：多为 HTTPS 被中间人检查或与镜像站证书链不一致。
# Debian apt 传统上允许用明文访问官方镜像；可改用 HTTP 镜像根（避免 TLS）：
#   --build-arg APT_MIRROR=http://mirrors.aliyun.com/debian \
#   --build-arg APT_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security

FROM debian:trixie-slim AS builder
ENV DEBIAN_FRONTEND=noninteractive

# 构建时访问外网需代理时：podman build --build-arg HTTPS_PROXY=$https_proxy ...
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY}

ARG APT_MIRROR=
ARG APT_SECURITY_MIRROR=
RUN set -eux; \
  if [ -n "$APT_SECURITY_MIRROR" ]; then \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/*.list; do \
      [ -f "$f" ] || continue; \
      sed -i "s|https://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" "$f"; \
      sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" "$f"; \
    done; \
  fi; \
  if [ -n "$APT_MIRROR" ]; then \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/*.list; do \
      [ -f "$f" ] || continue; \
      sed -i "s|https://deb.debian.org/debian|${APT_MIRROR}|g" "$f"; \
      sed -i "s|http://deb.debian.org/debian|${APT_MIRROR}|g" "$f"; \
    done; \
  fi

# LDC 链接需 cc + C 运行时（crt*.o 在 libc6-dev，随 build-essential）；-lz 需 zlib1g-dev。
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ldc \
    dub \
    build-essential \
    zlib1g-dev \
    git \
    ca-certificates \
    curl \
    unzip \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/* \
    && dub --version

WORKDIR /build

# 部分 dub 版本下无参 `dub fetch` 会报错；依赖获取与编译合并为一次 dub build（需含 views）。
COPY dub.json dub.selections.json ./
COPY src ./src
COPY views ./views

ENV DUB_HOME=/root/.dub
RUN --mount=type=cache,target=/root/.dub,sharing=locked \
    dub build --build=release-nobounds --compiler=ldc2 \
    && strip --strip-all target/micdn

# Collect dynamic deps (exclude glibc / dynamic loader — use those from the runtime base image).
RUN mkdir -p /pack \
    && for f in $(ldd target/micdn | awk '/=>/ {print $3}' | sort -u); do \
         [ -f "$f" ] || continue; \
         b=$(basename "$f"); \
         case "$b" in \
           libc.so*|ld-linux*) ;; \
           *) cp -L "$f" /pack/ ;; \
         esac; \
       done

# ---

FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive

ARG APT_MIRROR=
ARG APT_SECURITY_MIRROR=
RUN set -eux; \
  if [ -n "$APT_SECURITY_MIRROR" ]; then \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/*.list; do \
      [ -f "$f" ] || continue; \
      sed -i "s|https://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" "$f"; \
      sed -i "s|http://deb.debian.org/debian-security|${APT_SECURITY_MIRROR}|g" "$f"; \
    done; \
  fi; \
  if [ -n "$APT_MIRROR" ]; then \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/*.list; do \
      [ -f "$f" ] || continue; \
      sed -i "s|https://deb.debian.org/debian|${APT_MIRROR}|g" "$f"; \
      sed -i "s|http://deb.debian.org/debian|${APT_MIRROR}|g" "$f"; \
    done; \
  fi

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r micdn \
    && useradd -r -g micdn -d /var/lib/micdn -s /usr/sbin/nologin micdn \
    && mkdir -p /var/cache/micdn/asset /var/cache/micdn/www \
       /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local \
       /etc/micdn

COPY --from=builder /pack/ /usr/lib/micdn/
COPY --from=builder /build/target/micdn /usr/bin/micdn

ENV LD_LIBRARY_PATH=/usr/lib/micdn

COPY docker/micdn.xml /etc/micdn/micdn.xml

RUN chown -R micdn:micdn /var/cache/micdn /var/lib/micdn \
    && chown micdn:micdn /etc/micdn/micdn.xml \
    && chmod 755 /usr/bin/micdn

WORKDIR /var/lib/micdn

USER micdn

EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8888/admin/config.xml >/dev/null || exit 1

CMD ["micdn", "-f", "/etc/micdn/micdn.xml"]
