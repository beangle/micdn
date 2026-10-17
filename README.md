# micdn

A minimal, config-driven CDN: one HTTP process serving Maven, npm, WebJars and static assets,
documentation sites, and blob storage (with an optional S3-compatible API).

**License:** GPLv3 · **Version:** 0.4.0

## Services

| Service | Description |
|---------|-------------|
| **maven** | Maven repository: local cache plus upstream proxy, releases and SNAPSHOTs in one tree |
| **npm** | npm registry: local cache plus upstream registry, releases and dev versions in one tree |
| **static** | Front-end assets deployed from a Maven GAV (WebJar), an npm package or a local directory, served per bundle |
| **www** | Documentation sites and SPAs from npm or zip, with `try-file` fallback and `auto-deploy` (Linux inotify) |
| **native** | GraalVM native-image distributions (tar.gz) and bsdiff patches (`.diff`); single root, no upstream |
| **blob** | Object storage, with an optional S3-compatible API |
| **admin** | Localhost-only metrics (`/admin/metrics`), config view and reload |

Path attributes expand `${micdn.home}` and `~`.

## Endpoints

| Prefix | Description |
|--------|-------------|
| `/maven` | Releases proxy through `<remote>`, SNAPSHOTs through `<snapshot remote>`; an alias request without a timestamp `302`s to the newest timestamped file. Accepts `PUT` uploads (`mvn deploy`) once `<auth publish-key>` is set |
| `/npm` | Packuments and tarballs; releases proxy through `<remote>`, dev/prerelease versions through `<dev remote>`. Accepts `PUT` uploads (`npm publish`) once `<auth publish-key>` is set. Publish only: no unpublish, dist-tag, login or deprecate |
| `/native` | Fetch and distribute native bundles and incremental patches; accepts `PUT` uploads once `<auth publish-key>` is set |
| `/static` | Static asset bundles (when `<static>` is configured) |
| `/blob`, `/s3` | Blob storage and the S3-compatible API (when `<blob>` is configured) |
| `/admin` | Localhost-only metrics, config view and reload |
| `/*` | www fallback, matched by `<doc>` name (when `<www>` is configured) |

`<maven>`, `<npm>` and `<native>` only control whether the endpoint is mounted. Without the element
the repository still exists: the base falls back to `${micdn.home}/maven`, `${micdn.home}/npm` and
`${micdn.home}/native`, and the upstream to Maven Central / npmmirror (native has no upstream), so
`<jar>` / `<npm>` providers and `micdn install` need no such element. A missing trailing slash
(`/maven`) redirects to `/maven/`, which lists the local repository content.

## Quick start

```bash
# Requires ldc and dub (see docs/build_linux.md)
dub build --build=release-nobounds --compiler=ldc2

./target/micdn -f resources/micdn.xml    # serve HTTP
```

## Command line

| Command | Description |
|---------|-------------|
| `micdn -f <config>` | Start the HTTP server |
| `micdn -f <config> resolve` | Resolve and deploy all www/static, without starting HTTP |
| `micdn -f <config> deploy www manual` | Redeploy one doc; `deploy static bootstrap --force` for a bundle |
| `micdn -f <config> clean --yes` | Remove the deployed www/static output (maven/npm caches and blob data are kept) |
| `micdn -f <config> install <file>` | Add a local npm tarball or Maven artifact to the local repository |

`-f` accepts a local file, a directory (uses `DIR/micdn.xml`) or a URL (downloaded to `~/micdn.xml`).

`install` is strictly local: it reads local artifacts (tgz / jar / war / pom) and writes only the
local `<npm base>` / `<maven base>`, never contacting a registry. It derives `dist.integrity`,
`dist-tags` and `maven-metadata.xml` from what it writes, and merges into an existing packument
instead of overwriting it. The `dist.tarball` URL is stored as an `{origin}` placeholder and
resolved per request, so one packument works behind any host name.

## Configuration

```xml
<micdn home="/var/lib/micdn" listen="127.0.0.1:8080">
  <maven base="${micdn.home}/maven">
    <remote url="https://repo1.maven.org/maven2/" />
    <snapshot remote="https://oss.sonatype.org/content/repositories/snapshots/" />
  </maven>
  <npm base="${micdn.home}/npm">
    <remote url="https://registry.npmmirror.com" />
    <dev remote="https://registry.example.com/dev" />
  </npm>
  <static base="/var/cache/micdn/asset">
    <bundle name="bootstrap">
      <jar gav="org.webjars:bootstrap:4.6.1" />
    </bundle>
    <bundle name="local">
      <dir location="/srv/static/local" />
    </bundle>
  </static>
  <www base="/var/cache/micdn/www">
    <doc name="manual" zip="${micdn.home}/releases/manual.zip"
         inner="dist" try-file="index.html" auto-deploy="true" />
  </www>
  <blob base="${micdn.home}/blob" max-size="50M">
    <bucket name="local" key="..." />
  </blob>
  <!-- publish-key gates PUT; optional download-key gates artifact GETs -->
  <auth publish-key="s3cret" max-size="64M" />
</micdn>
```

A `<bundle>` takes either `<jar>` / `<npm>` providers (extracted and indexed at deploy time) or
`<dir>` (symlinked, no index). A fuller sample lives in [`resources/micdn.xml`](resources/micdn.xml).

## Publishing and auth

`<auth>` is the only gate for `/maven`, `/npm` and `/native`. A non-empty `publish-key` mounts `PUT`
(`Authorization: Bearer`, `Basic`, or `X-Micdn-Token`); the optional `download-key` requires the same
credential for file GETs, while `HEAD` and directory listings stay open. Both keys should only
travel over HTTPS. The upload limit defaults to `64M` and doubles as `maxRequestSize` when `<blob>`
is absent — raise it for native bundles, which are usually tens of megabytes.

```bash
npm publish --tag dev --registry http://127.0.0.1:8888/npm/
mvn deploy -DaltDeploymentRepository=local::default::http://127.0.0.1:8888/maven
```

## gzip

Text assets (js / css / html / svg / json) are pre-compressed to `path.gz` sidecars at deploy time
and sent with `Content-Encoding: gzip` when the client accepts it, so nothing is compressed per
request. Files under 1KB or over 8MB, already-compressed formats, and `Range` requests are excluded.
www docs participate by default (`auto-gzip="false"` opts out); `<dir>` bundles never do.

## Downloads

Every upstream download (maven, npm, assets, remote config) goes through `curlDownload`
(`src/micdn/web/curl.d`): the default build shells out to the host `curl` command, while
`-c executable-static` links libcurl statically and needs no host curl. Downloads write a `.part`
file first and rename on success.

## Documentation

| Document | Contents |
|----------|----------|
| [docs/guide.md](docs/guide.md) | Full reference: config, endpoints, local publishing, gzip, downloads (Chinese) |
| [docs/build_linux.md](docs/build_linux.md) | Linux build, RPM / deb / SRPM packaging |
| [docs/build_on_fedora.md](docs/build_on_fedora.md) | Fedora local RPM / SRPM and COPR publishing |
| [docs/build_container.md](docs/build_container.md) | Podman / OCI images |
| [docs/build_static_portable.md](docs/build_static_portable.md) | Fully static builds and portability |
| [docs/build_aur.md](docs/build_aur.md) | Arch AUR |
| [docs/maintenance.md](docs/maintenance.md) | systemd, `micdn`/`beangle` permissions, resolve/deploy, auto-deploy |
| [docs/reverse_proxy.md](docs/reverse_proxy.md) | nginx / varnish caching, haproxy compression |
| [docs/merged_repo.md](docs/merged_repo.md) | Merged release/dev repositories and single-entry design |
| [docs/auth.md](docs/auth.md) | Read/write access control: semantics and client credentials |
| [docs/native.md](docs/native.md) | The `/native` distribution repository |
| [docs/reload.md](docs/reload.md) | Configuration reload |
| [docs/stress_test.md](docs/stress_test.md) | Stress-test guide and results |
| [docs/release-v0.4.0.md](docs/release-v0.4.0.md) | Current release notes |

Packaging scripts (each starts from `dub clean` and an emptied `target/`):

```bash
./scripts/build_rpm.sh
./scripts/build_deb.sh
./scripts/build_image.sh
```

## Development

```bash
dub test
```

Requires dub ≥ 1.34 and LDC ≥ 1.32 (see `dub.json`). Blob metadata relies on Linux `user.*`
extended attributes, so exercise the full feature set on Linux.
