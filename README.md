# setup-vcpkg-nuget-cache

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[日本語版 README はこちら / Japanese README](README.ja.md)

A GitHub Action (and matching local-machine PowerShell script) that
configures vcpkg's binary cache to use a [GitHub Packages][github-packages]
NuGet feed. Same code path runs in CI and on developer laptops, so
cache hits work in both places without configuration drift.

[github-packages]: https://github.com/features/packages

## What it does

The action does three things in one step:

1. Pins the vcpkg checkout to a specific commit SHA — read from your
   `vcpkg.json`'s `builtin-baseline`, or passed in explicitly. This
   stabilises the ABI hashes vcpkg uses for cache keys, so a `windows-latest`
   runner image refresh doesn't invalidate your cache.
2. Registers the GitHub Packages NuGet feed as a vcpkg binary source.
3. Exports `VCPKG_ROOT` and `VCPKG_BINARY_SOURCES` so subsequent steps
   (and Visual Studio's auto-vcpkg integration) pick up the cache
   automatically.

The same logic, shipped as `tools/Setup-VcpkgCache.ps1`, can be invoked
directly from a local PowerShell session — see [Local development](#local-development).

If you've never set up vcpkg binary caching before, **[read the vcpkg
guide first](docs/vcpkg-guide.md)** ([日本語](docs/vcpkg-guide.ja.md)).
It explains the *why* behind every input, with diagrams and failure
stories.

## Quick start

### 1. Add a `vcpkg.json` to your repo

```json
{
  "name": "my-app",
  "version-string": "0.1.0",
  "dependencies": [
    "libspatialite",
    "boost-system"
  ],
  "builtin-baseline": "84bab45d415d22042bd0b9081aea57f362da3f35"
}
```

The `builtin-baseline` is a `microsoft/vcpkg` release tag's commit SHA.
See [Picking a SHA](docs/vcpkg-guide.md#6-how-to-pick-a-sha) in the guide
if you're unsure which to use.

### 2. Wire up the action in your workflow

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # publishing to GitHub Packages
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Build
        run: msbuild MyApp.sln /p:Configuration=Release /p:Platform=x64
        # msbuild auto-runs `vcpkg install` thanks to VS integration.
        # Cache hit: download. Cache miss: build, then push the nupkg.
```

That's it. No `vcpkg-commit` input — the action reads the SHA from
your `vcpkg.json`'s `builtin-baseline`.

If you don't use VS integration, run `vcpkg install` explicitly:

```yaml
      - run: vcpkg install --triplet=x64-windows-static-md
```

What you'll see in the Actions log:

- **First run** (cold cache): `vcpkg install` builds dependencies from
  source (~25 min for `libspatialite` + transitive deps), then uploads
  each built port to GitHub Packages.
- **Subsequent runs** (warm cache): vcpkg downloads prebuilt `.nupkg`
  files instead of building. Typically 1–2 minutes total.

### 3. Local development

`secrets.GITHUB_TOKEN` is CI-only — locally you need either a Personal
Access Token or a `gh` CLI token. Once per shell session:

```powershell
# Easiest: borrow the token from GitHub CLI (one-time: gh auth refresh -s read:packages)
.\tools\Setup-VcpkgCache.ps1 -Token (gh auth token) -Mode read

# Or: classic PAT from github.com/settings/tokens (read:packages scope)
$env:GH_TOKEN = "ghp_..."
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# Now in the same shell:
vcpkg install                    # cache hits from the GitHub Packages feed
# Or open the .sln in VS and just build — same effect.
```

Get the script into your repo (one-time):

```powershell
New-Item -ItemType Directory -Force -Path tools | Out-Null
Invoke-WebRequest `
    -Uri https://raw.githubusercontent.com/jumboly/setup-vcpkg-nuget-cache/v1/tools/Setup-VcpkgCache.ps1 `
    -OutFile tools/Setup-VcpkgCache.ps1
```

Commit it. Re-fetch when you upgrade the action's major version.

## Inputs

| Name            | Required | Default                  | Description |
|-----------------|----------|--------------------------|-------------|
| `token`         | **yes**  | —                        | GitHub token (`packages:write` to publish, `:read` to consume). `${{ secrets.GITHUB_TOKEN }}` works for same-owner publishing. |
| `mode`          | no       | `readwrite`              | `read` (consume only) or `readwrite` (publish on cache miss). |
| `vcpkg-commit`  | no       | (auto from `vcpkg.json`) | Override SHA. Useful when you don't have a `vcpkg.json` (classic mode). |
| `manifest-path` | no       | `./vcpkg.json`           | Path to the `vcpkg.json` whose `builtin-baseline` is the pin source. |
| `feed-url`      | no       | derived                  | NuGet feed URL. Default: `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json`. |
| `feed-name`     | no       | `github-packages`        | Internal NuGet source key. |
| `vcpkg-root`    | no       | derived                  | Path to vcpkg. Default resolution: `$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg`. |

## Outputs

| Name           | Description                                            |
|----------------|--------------------------------------------------------|
| `feed-url`     | Resolved feed URL.                                     |
| `vcpkg-root`   | Resolved vcpkg root path.                              |
| `vcpkg-commit` | SHA the vcpkg checkout was pinned to.                  |

## Authentication and permissions

- **Publisher mode** (`readwrite`): the calling job needs
  `permissions: { contents: read, packages: write }`.
- **Consumer mode** (`read`): `packages: read` is enough.
- **Same-owner publishing**: `${{ secrets.GITHUB_TOKEN }}` works out of
  the box.
- **Cross-owner publish or read**: a Personal Access Token (PAT) with
  `write:packages` (or `read:packages`) is required.
- **Pull requests from forks**: `GITHUB_TOKEN` does not get
  `packages:write`, so push is rejected and the build falls back to
  source. Same behaviour as `actions/cache`.

## Platform support

Windows runners (`windows-latest`, `windows-2022`, etc.) only. vcpkg is
pre-installed at `C:\vcpkg` on GitHub-hosted Windows runners. Linux and
macOS are out of scope: `nuget.exe` requires Mono there, and binary
caching for Windows-targeted MSVC builds is the design centre.

## Read-only consumer mode

```yaml
permissions:
  contents: read
  packages: read
steps:
  - uses: actions/checkout@v4
  - uses: jumboly/setup-vcpkg-nuget-cache@v1
    with:
      mode: read
      feed-url: https://nuget.pkg.github.com/<publisher-account>/index.json
      token: ${{ secrets.GITHUB_TOKEN }}
  - run: msbuild MyApp.sln /p:Platform=x64
    # Cache hit: download. Cache miss: build locally (NOT pushed).
```

## Going deeper

If you want to understand:

- What vcpkg actually is (no central binary registry — it builds from source)
- Classic mode vs manifest mode
- Why pinning the vcpkg checkout matters (and what an "ABI hash" is)
- How `builtin-baseline` and `vcpkg-commit` relate
- How to pick a vcpkg release SHA
- How VS integration auto-runs `vcpkg install`
- The `x64-windows-static-md` triplet pitfall
- Multi-solution repository patterns
- Common misconceptions and FAQ

read [`docs/vcpkg-guide.md`](docs/vcpkg-guide.md) ([日本語](docs/vcpkg-guide.ja.md)).

## Why this vs `actions/cache`?

Most existing tutorials cache `vcpkg/archives` with `actions/cache`.
That works but has structural issues:

| Property                                | `actions/cache` | This action (NuGet)    |
|-----------------------------------------|-----------------|------------------------|
| Cache hit granularity                   | tarball-wide    | per port               |
| Survives `builtin-baseline` updates     | ❌ all-miss     | ✅ unchanged ports hit |
| Survives test failures (post step)      | ❌ skipped save | ✅ port-by-port push   |
| Eviction policy                         | 7 days idle     | persistent             |
| Cross-repository sharing (same owner)   | ❌              | ✅                     |
| Local development hits the same cache   | ❌              | ✅                     |

The NuGet approach scales better as the dependency graph grows, and
extends naturally to local builds.

## License

Dual-licensed under either:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

Contributions intentionally submitted for inclusion in this work, as
defined in the Apache-2.0 license, shall be dual-licensed as above
without any additional terms or conditions.
