# syntax=docker/dockerfile:1
# Alpine（musl）多阶段构建：在镜像内用 apk 的 ldc+dub 编译，与运行时同为 musl。
#
# 构建：./scripts/build_image.sh（见 docs/CONTAINER_BUILD.md）
# apk 源已固定为华为云（见下方 sed）；拉取 FROM 需代理时在运行 podman 的 shell 里 export。详见 docs/CONTAINER_BUILD.md。

FROM alpine:3.23 AS builder
ENV DUB_HOME=/root/.dub

# /var/cache/apk：由 ./scripts/build_image.sh 挂载宿主机目录（默认 ~/.cache/alpine-apk），与 ~/.dub 同理；勿无挂载构建。
# apk-tools v3（Alpine 3.23+）默认不把 .apk 写入缓存，只会留下 APKINDEX；须加 --cache-packages 才会复用宿主机卷里的包。
# 勿用 apk add --no-cache（会清空 /var/cache/apk，与持久挂载冲突）。
RUN set -eux; \
  sed -i \
    -e 's|https://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    -e 's|http://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    /etc/apk/repositories; \
  apk add --cache-packages \
    ldc \
    dub \
    build-base \
    binutils \
    zlib-dev \
    openssl-dev \
    git \
    ca-certificates \
    curl \
    unzip \
    bash

WORKDIR /build

# dub 依赖：由宿主机 ./scripts/build_image.sh 先 dub fetch，再 -v $HOME/.dub:/root/.dub；此处不再 RUN dub fetch。
# 勿手写无挂载的 podman build，否则 dub 会把包写入镜像层、体积暴涨。
# 另可选：mkdir -p scripts/container/host-dub-cache && cp -a ~/.dub/. scripts/container/host-dub-cache/ 后取消下一行 COPY（勿提交该目录，见 .gitignore）。
# COPY scripts/container/host-dub-cache/ /root/.dub/
COPY dub.json dub.selections.json ./

COPY src ./src
COPY views ./views

RUN dub build --build=release-nobounds --compiler=ldc2 \
    && strip --strip-unneeded target/micdn

# musl：跳过 libc 与动态加载器，其余 .so 打进 /pack
RUN mkdir -p /pack \
    && for f in $(ldd target/micdn | awk '/=>/ {print $3}' | sort -u); do \
         [ -f "$f" ] || continue; \
         b=$(basename "$f"); \
         case "$b" in \
           libc.so*|ld-linux*|ld-musl*|libc.musl*) ;; \
           *) cp -L "$f" /pack/ ;; \
         esac; \
       done

# ---

FROM alpine:3.23
RUN set -eux; \
  sed -i \
    -e 's|https://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    -e 's|http://dl-cdn.alpinelinux.org/alpine|https://mirrors.huaweicloud.com/alpine|g' \
    /etc/apk/repositories; \
  apk add --cache-packages \
    ca-certificates \
    curl \
    su-exec \
    && addgroup -S micdn \
    && adduser -S -D -G micdn -h /var/lib/micdn -s /sbin/nologin micdn \
    && mkdir -p /var/cache/micdn/asset /var/cache/micdn/www \
       /var/lib/micdn/maven /var/lib/micdn/npm /var/lib/micdn/local \
       /etc/micdn

COPY --from=builder /pack/ /usr/lib/micdn/
COPY --from=builder /build/target/micdn /usr/bin/micdn

ENV LD_LIBRARY_PATH=/usr/lib/micdn

COPY scripts/container/micdn.xml /etc/micdn/micdn.xml
COPY scripts/container/entrypoint.sh /entrypoint.sh

RUN chown -R micdn:micdn /var/cache/micdn /var/lib/micdn \
    && chown micdn:micdn /etc/micdn/micdn.xml \
    && chmod 755 /usr/bin/micdn /entrypoint.sh

WORKDIR /var/lib/micdn

EXPOSE 8888
# 不设 HEALTHCHECK：Podman 默认以 OCI 格式提交时会忽略该指令并告警；探活请在编排层（如 K8s probe）配置。

ENTRYPOINT ["/entrypoint.sh"]
CMD ["micdn", "-f", "/etc/micdn/micdn.xml"]
