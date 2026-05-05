# setup-vcpkg-nuget-cache

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[日本語版 README はこちら / Japanese README](README.ja.md)

A composite GitHub Action that caches [vcpkg][vcpkg] ports as NuGet packages
in [GitHub Packages][github-packages], and (optionally) runs `vcpkg install`
for you. Designed for the **publisher side** of vcpkg's [binary caching
feature][vcpkg-binarycaching].

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages
[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

> **Status: pre-1.0, work in progress.**
> The composite action is implemented; end-to-end CI validation against a
> real GitHub Packages feed is pending. See
> [`.claude/HANDOFF.md`](.claude/HANDOFF.md) for the rollout plan.

## Why

Building vcpkg ports from source on every CI run is slow — `libspatialite`
plus its transitive dependencies takes ~25 minutes on `windows-latest`.
vcpkg's binary caching solves this by caching pre-built ports as NuGet
packages, but the canonical pattern requires nontrivial workflow boilerplate
(`nuget.exe` fetch, source registration, env wiring, `vcpkg install`). This
action wraps all of it behind a single `uses:`.

Compared to the `actions/cache`-over-`vcpkg/archives` pattern that most
existing tutorials describe:

| Property                                  | `actions/cache` | This action (NuGet) |
|-------------------------------------------|-----------------|---------------------|
| Cache hit granularity                     | tarball-wide    | per port            |
| Survives `vcpkg HEAD` updates             | ❌ all-miss     | ✅ unchanged ports hit |
| Survives `cargo test` / job failure       | ❌ skipped save | ✅ port-by-port push |
| Eviction policy                           | 7 days idle     | persistent          |
| Cross-repository sharing (same owner)     | ❌              | ✅                  |
| Initial setup cost                        | low             | low (this action)   |

## Quick start (publisher: builds and uploads)

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          ports: libspatialite
          triplet: x64-windows-static-md
          token: ${{ secrets.GITHUB_TOKEN }}
      # ports are now installed locally AND uploaded to
      # https://nuget.pkg.github.com/<your-account>/
      - run: |
          # Use the installed libraries from cmake / msbuild / cargo / ...
```

## Quick start (consumer: download only)

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@v4
      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          mode: read
          feed-url: https://nuget.pkg.github.com/some-publisher-account/index.json
          token: ${{ secrets.GITHUB_TOKEN }}
      - run: |
          C:\vcpkg\vcpkg.exe install --triplet=x64-windows-static-md libspatialite
          # vcpkg pulls binaries from the feed; on miss it builds locally
          # but does not push (mode: read).
```

## Inputs

| Name         | Required | Default            | Description |
|--------------|----------|--------------------|-------------|
| `ports`      | no       | `""`               | Comma-separated vcpkg ports to install. Empty = setup env only. |
| `triplet`    | no       | `""`               | vcpkg triplet. Required when `ports` is non-empty. |
| `feed-url`   | no       | derived            | NuGet feed URL. Default: `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json`. |
| `feed-name`  | no       | `github-packages`  | Internal NuGet source key. |
| `token`      | **yes**  | —                  | GitHub token with `packages:write` (or `:read` for `mode: read`). |
| `vcpkg-root` | no       | derived            | Path to vcpkg. Default: `$VCPKG_INSTALLATION_ROOT`, then `$VCPKG_ROOT`, then `C:\vcpkg` / `/usr/local/share/vcpkg`. |
| `mode`       | no       | `readwrite`        | `read` (consumer-only) or `readwrite` (publisher). |

## Outputs

| Name         | Description                |
|--------------|----------------------------|
| `feed-url`   | Resolved feed URL.         |
| `vcpkg-root` | Resolved vcpkg root path.  |

## Authentication and permissions

- The calling job needs `permissions: { contents: read, packages: write }`
  for publisher mode, or `packages: read` for consumer-only mode.
- For publishing within the same GitHub account/org as the calling repo:
  `${{ secrets.GITHUB_TOKEN }}` works.
- For cross-org publish (or read from another account's feed): a Personal
  Access Token with `write:packages` (or `read:packages`) is required.
- Pull requests from forks: `GITHUB_TOKEN` does not get `packages:write`,
  so push is rejected. The cache miss falls back to building from source.
  This matches `actions/cache` behaviour.

## Platform support

| Runner            | Status                                                                  |
|-------------------|-------------------------------------------------------------------------|
| `windows-latest`  | Primary target. vcpkg is pre-installed at `C:\vcpkg`.                   |
| `ubuntu-latest`   | Planned. Caller must bootstrap vcpkg first; Mono required for `nuget.exe`. |
| `macos-latest`    | Planned. Caller must bootstrap vcpkg first; Mono required for `nuget.exe`. |

## Comparison to similar actions

- [`lukka/run-vcpkg`][run-vcpkg] — Mature, widely used. Uses GitHub Actions
  Cache as the binary cache backend. Does **not** publish to NuGet feeds.
  Use this if you want a single-repo, ephemeral cache.
- [`johnwason/vcpkg-action`][johnwason] — Similar scope to `run-vcpkg`,
  also `actions/cache`-based. Does **not** publish to NuGet.
- [`LegalizeAdulthood/vcpkg-nuget-cache`][legalize] — A consumer-side helper
  that configures `VCPKG_BINARY_SOURCES` for an existing feed. Does **not**
  publish; use it on the read side, this action on the write side.

This action fills the gap where the publisher side needs to upload built
ports to a long-lived NuGet feed.

[run-vcpkg]: https://github.com/marketplace/actions/run-vcpkg
[johnwason]: https://github.com/johnwason/vcpkg-action
[legalize]: https://github.com/LegalizeAdulthood/vcpkg-nuget-cache

## License

Dual-licensed under either:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

Contributions intentionally submitted for inclusion in this work, as defined
in the Apache-2.0 license, shall be dual-licensed as above without any
additional terms or conditions.
