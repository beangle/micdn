#!/bin/sh
# 挂载命名卷或绑定目录时，宿主机上的目录常为 root 拥有；启动前修正属主后再以 micdn 运行进程。
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -e
chown -R micdn:beangle /var/cache/micdn /var/lib/micdn /var/log/micdn 2>/dev/null || true
# reload 以 micdn 用户运行：/etc/micdn 需组可写，micdn.conf 只需组可读。
chown root:beangle /etc/micdn 2>/dev/null || true
chmod 2775 /etc/micdn 2>/dev/null || true
if [ -f /etc/micdn/micdn.conf ]; then
  chown root:beangle /etc/micdn/micdn.conf 2>/dev/null || true
  chmod 0640 /etc/micdn/micdn.conf 2>/dev/null || true
fi
if command -v su-exec >/dev/null 2>&1; then
  exec su-exec micdn "$@"
fi
if command -v runuser >/dev/null 2>&1; then
  exec runuser -u micdn -- "$@"
fi
if command -v setpriv >/dev/null 2>&1; then
  exec setpriv --reuid="$(id -u micdn)" --regid="$(id -g micdn)" --clear-groups -- "$@"
fi
echo "entrypoint: need su-exec, runuser, or setpriv" >&2
exit 1
