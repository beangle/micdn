#!/bin/bash
# 将本地 npm 包 tgz 装入 micdn 的 npm 缓存目录，并刷新该包的 packument。
#
# 用法:
#   scripts/npm_add.sh <package.tgz> [--base <npm 缓存目录>] [--registry <对外 URL>]
#
# 缓存布局与 micdn 的 NpmRepo.localTarball 一致:
#   {base}/{scope|_}/{name}/{version}/{name}-{version}.tgz
# packument 写入 {base}/@scope/name（无 scope 时为 {base}/name），
# 供消费方以 `@scope:registry=<registry>` 方式安装。
#
# 示例:
#   scripts/npm_add.sh ~/npm-local/beangle-ems-app-0.0.2.tgz
#   curl -I http://127.0.0.1:8080/npm/@beangle/ems-app/-/ems-app-0.0.2.tgz

set -e -o pipefail

base="$HOME/npm"
registry="http://127.0.0.1:8080/npm"
tgz=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --registry) registry="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) tgz="$1"; shift ;;
  esac
done

[ -n "$tgz" ] || { echo "usage: $0 <package.tgz> [--base <dir>] [--registry <url>]" >&2; exit 2; }
[ -f "$tgz" ] || { echo "not found: $tgz" >&2; exit 1; }
command -v node >/dev/null || { echo "node is required" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }

tgz="$(cd "$(dirname "$tgz")" && pwd)/$(basename "$tgz")"
registry="${registry%/}"

node - "$tgz" "$base" "$registry" <<'JS'
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const crypto = require('crypto');

const [tgz, base, registry] = process.argv.slice(2);

const manifestOf = (file) =>
  JSON.parse(cp.execSync(`tar -xzOf ${JSON.stringify(file)} package/package.json`).toString());
const digestOf = (file) => {
  const buf = fs.readFileSync(file);
  return {
    integrity: 'sha512-' + crypto.createHash('sha512').update(buf).digest('base64'),
    shasum: crypto.createHash('sha1').update(buf).digest('hex'),
  };
};
const compare = (a, b) => {
  const parse = (v) => {
    const [core, pre = ''] = v.split('-');
    return { nums: core.split('.').map((n) => parseInt(n, 10) || 0), pre: pre ? pre.split('.') : [] };
  };
  // semver 预发布比较：逐段比，数字段按数值、低于字母数字段，段数多者大；无预发布为正式版，最大。
  const comparePre = (x, y) => {
    if (!x.length || !y.length) return x.length === y.length ? 0 : x.length ? -1 : 1;
    for (let i = 0; i < Math.min(x.length, y.length); i++) {
      const nx = /^\d+$/.test(x[i]);
      const ny = /^\d+$/.test(y[i]);
      if (nx && ny) {
        if (+x[i] !== +y[i]) return +x[i] < +y[i] ? -1 : 1;
      } else if (nx !== ny) {
        return nx ? -1 : 1;
      } else if (x[i] !== y[i]) {
        return x[i] < y[i] ? -1 : 1;
      }
    }
    return x.length === y.length ? 0 : x.length < y.length ? -1 : 1;
  };
  const [pa, pb] = [parse(a), parse(b)];
  for (let i = 0; i < 3; i++) {
    const d = (pa.nums[i] || 0) - (pb.nums[i] || 0);
    if (d !== 0) return d;
  }
  return comparePre(pa.pre, pb.pre);
};

const pkg = manifestOf(tgz);
if (!pkg.name || !pkg.version) throw new Error('package.json lacks name or version');

const scoped = pkg.name.startsWith('@');
const slash = pkg.name.indexOf('/');
const scope = scoped ? pkg.name.slice(1, slash) : '_';
const bare = scoped ? pkg.name.slice(slash + 1) : pkg.name;

const versionsDir = path.join(base, scope, bare);
const destDir = path.join(versionsDir, pkg.version);
fs.mkdirSync(destDir, { recursive: true });
const dest = path.join(destDir, `${bare}-${pkg.version}.tgz`);
fs.copyFileSync(tgz, dest);

const isPrerelease = (v) => v.includes('-');

const versions = fs
  .readdirSync(versionsDir, { withFileTypes: true })
  .filter((e) => e.isDirectory() && fs.existsSync(path.join(versionsDir, e.name, `${bare}-${e.name}.tgz`)))
  .map((e) => e.name)
  .sort(compare);

// dist-tags.latest 遵循 npm 惯例：取最高正式版本；只有预发布版本时才退化为最高版本，
// 避免 -dev./-SNAPSHOT 之类的开发构建顶替 latest。
const stableVersions = versions.filter((v) => !isPrerelease(v));
const latestCandidates = stableVersions.length ? stableVersions : versions;
const latest = latestCandidates[latestCandidates.length - 1];

// 预发布通道 tag：latest 只给正式版，开发预览走 dev/next/beta/rc 等通道，
// 消费方用 `@scope/name@dev` 跟随最新预览（与 micdn 按需合成 packument 的口径一致）。
const channels = ['dev', 'next', 'beta', 'rc', 'alpha', 'canary'];
const distTags = { latest };
for (const channel of channels) {
  const best = versions.filter((v) => isPrerelease(v) && v.split('-')[1].split('.')[0] === channel).pop();
  if (best) distTags[channel] = best;
}
const manifest = (version) => {
  const file = path.join(versionsDir, version, `${bare}-${version}.tgz`);
  const v = manifestOf(file);
  for (const key of ['scripts', 'devDependencies', 'publishConfig', 'pnpm']) delete v[key];
  v.dist = {
    tarball: `${registry}/${pkg.name}/-/${bare}-${version}.tgz`,
    ...digestOf(file),
  };
  return v;
};

const now = new Date().toISOString();
const packument = {
  _id: pkg.name,
  name: pkg.name,
  'dist-tags': distTags,
  versions: Object.fromEntries(versions.map((v) => [v, manifest(v)])),
  time: { created: now, modified: now, ...Object.fromEntries(versions.map((v) => [v, now])) },
  description: pkg.description,
  license: pkg.license,
  homepage: pkg.homepage,
  repository: pkg.repository,
  bugs: pkg.bugs,
};

const packumentFile = path.join(base, pkg.name);
fs.mkdirSync(path.dirname(packumentFile), { recursive: true });
fs.writeFileSync(packumentFile, JSON.stringify(packument, null, 2) + '\n');

console.log(`tarball    ${dest}`);
console.log(`packument  ${packumentFile}`);
console.log(`versions   ${versions.join(', ')}`);
console.log(`url        ${registry}/${pkg.name}/-/${bare}-${pkg.version}.tgz`);
JS
