# setup-vcpkg-nuget-cache

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[日本語版 README はこちら / Japanese README](README.ja.md)

A GitHub Action that makes Windows + Visual Studio CI builds with
[vcpkg][vcpkg] much faster, by caching built dependencies as NuGet
packages in your account's [GitHub Packages][github-packages] feed.
The first CI run is the usual cold build; every run after that downloads
prebuilt binaries instead of recompiling.

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages

> **Status: pre-1.0, work in progress.**
> The action is implemented and tested end-to-end on `windows-latest`.
> v1.0 tag and Marketplace publish are still pending.

## Who this is for

You're working on a C++ project (or a Rust / .NET project that depends on
C++ libraries) that:

- builds on **Windows** with **Visual Studio / MSVC**, and
- uses **vcpkg** to install third-party libraries (`boost`, `libcurl`,
  `proj`, etc.), and
- has GitHub Actions CI that currently rebuilds those libraries from
  source on every push (15–40 minutes per run for non-trivial graphs).

## What it does

vcpkg has a built-in feature called [binary caching][vcpkg-binarycaching]:
once vcpkg has built a library for a given configuration, it can stash
the compiled artefacts and reuse them next time. One supported backend is
a NuGet feed — and GitHub Packages provides a free NuGet feed scoped to
your GitHub account.

Wiring vcpkg to a GitHub Packages NuGet feed in CI normally takes ~30
lines of YAML (`vcpkg fetch nuget` → `nuget sources add` → `setapikey` →
env wiring → `vcpkg install`). **This action collapses all of that to a
single `uses:` line.**

[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

## Quick start

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # required so the job can publish to GitHub Packages
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          ports: libspatialite,boost-system     # vcpkg ports to install (comma-separated)
          triplet: x64-windows-static-md        # see the Triplets section below
          token: ${{ secrets.GITHUB_TOKEN }}

      # Your dependencies are now installed under
      # $VCPKG_INSTALLATION_ROOT/installed/x64-windows-static-md/.
      # Continue with cmake / msbuild / cargo / etc.
      - name: Build
        run: cmake --preset windows-msvc && cmake --build out
```

What you'll see in the Actions log:

- **First run** (cold cache): the action runs `vcpkg install`, which
  builds your dependencies from source (~25 min for `libspatialite` and
  its transitive deps), then uploads each built port to GitHub Packages.
- **Subsequent runs** (warm cache): vcpkg downloads prebuilt `.nupkg`
  files instead of building. Typically 1–2 minutes total.

GitHub-hosted `windows-latest` already has vcpkg pre-installed at
`C:\vcpkg`, so you don't need to bootstrap it.

## Reproducibility: pinning vcpkg

By default, this action uses whichever vcpkg checkout the runner image
ships. The `windows-latest` image is refreshed roughly every two weeks,
which moves the `C:\vcpkg` git tree to a newer commit. Because vcpkg's
port versions live as `ports/<name>/vcpkg.json` files inside that tree,
each refresh can change the version of any port — and any of its
transitive dependencies — that you install. Once a dependency's version
shifts, vcpkg's ABI hash changes, the existing NuGet entry no longer
matches, and the cache misses (often for the entire dependency graph,
since hashes propagate up through the tree).

To opt in to deterministic builds, pass a vcpkg commit SHA via
`vcpkg-commit`:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    ports: libspatialite
    triplet: x64-windows-static-md
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35   # microsoft/vcpkg 2025.12.12 release
```

When set, the action runs `git fetch && git checkout <sha>` in the vcpkg
root and re-bootstraps `vcpkg.exe`, so the entire ports tree (and
therefore every port version your build resolves to) is fixed. Cache
hits then survive runner image refreshes — only an MSVC or Windows SDK
upgrade can still invalidate them. Tags and branch names also work but
SHAs are recommended for reproducibility.

### How to pick a SHA

Use a release tag commit from `microsoft/vcpkg` rather than an arbitrary
`master` SHA — releases are tested as a coherent snapshot of all ports.
Two ways to find one:

- **From the browser**: open
  [microsoft/vcpkg/releases](https://github.com/microsoft/vcpkg/releases),
  pick the release you want (latest is usually fine), then copy the
  commit SHA shown next to the tag.
- **From the shell**:

  ```bash
  git ls-remote --tags https://github.com/microsoft/vcpkg.git \
    | grep -E 'refs/tags/[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' \
    | tail -5
  # 84bab45d415d22042bd0b9081aea57f362da3f35	refs/tags/2025.12.12
  # ...                                       (most recent at the bottom)
  ```

  Copy the 40-character SHA from the leftmost column.

### Upgrading

Pinning is opt-in stagnation: until you change the SHA, your build keeps
using the old vcpkg. To take a newer ports snapshot:

1. Pick a new SHA (see above).
2. Update `vcpkg-commit:` in your workflow and commit.
3. The next CI run cold-builds against the new ports tree and publishes
   fresh nupkgs to your feed.

Plan to bump it every few months, or when you need a port version that
landed upstream after your current pin.

### Relationship to manifest mode

`vcpkg-commit` is orthogonal to vcpkg's manifest mode (`vcpkg.json` +
`builtin-baseline`); both can be used together if your project consumes
vcpkg in manifest mode. In that case, point `vcpkg-commit` and
`builtin-baseline` at the same SHA so the tool and the resolved port
versions stay in sync.

## Triplets

A *triplet* tells vcpkg what to build for: architecture + OS + linkage +
CRT. Most VS-built C++ projects pick one of:

| Triplet                  | Meaning |
|--------------------------|---------|
| `x64-windows`            | 64-bit Windows, **DLLs** (each library is a separate `.dll`) |
| `x64-windows-static`     | 64-bit Windows, **static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64-bit Windows, **static `.lib`** + **dynamic CRT** (`/MD`) — typical for VS-built apps that need a single redistributable `.exe` |

If unsure, start with `x64-windows-static-md`. For ARM64 builds, replace
`x64` with `arm64`.

## Verifying it works

After the first successful run:

1. Visit `https://github.com/<your-account>?tab=packages`. You should see
   the ports you specified (and their transitive dependencies) listed as
   NuGet packages.
2. Re-run the workflow. The `setup-vcpkg-nuget-cache` step plus the
   `vcpkg install` it triggers should finish in 1–2 minutes. The vcpkg
   log lines will switch from `Building from source` to messages about
   restoring from the NuGet feed.

## Common errors

| Symptom | Cause / fix |
|---------|-------------|
| `triplet input is required when ports is non-empty` | You set `ports:` but not `triplet:`. Add a triplet (see above). |
| `401 Unauthorized` when the action tries to push | The job lacks `packages: write` permission. Add the `permissions:` block from the Quick start. |
| All ports rebuilding on what should be a warm run | Either the runner image's MSVC / Windows SDK was upgraded, or its bundled vcpkg checkout moved (port versions changed). The first you cannot avoid; the second is what `vcpkg-commit` is for — see [Reproducibility](#reproducibility-pinning-vcpkg). |
| Pull request from a fork: push fails | Expected. `GITHUB_TOKEN` from fork PRs cannot get `packages: write` for security reasons. Either gate publishing behind `if: github.event.pull_request.head.repo.full_name == github.repository`, or accept the cold build for fork PRs. |

## Inputs

| Name         | Required | Default            | Description |
|--------------|----------|--------------------|-------------|
| `ports`      | no       | `""`               | Comma-separated vcpkg ports to install. Empty means setup the feed only (let your own step run `vcpkg install`). |
| `triplet`    | no       | `""`               | vcpkg triplet (see Triplets section). Required when `ports` is non-empty. |
| `feed-url`   | no       | derived            | NuGet feed URL. Default: `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json` (i.e. your account). |
| `feed-name`  | no       | `github-packages`  | Internal NuGet source key. Rarely changed. |
| `token`      | **yes**  | —                  | GitHub token with `packages:write` (or `:read` for `mode: read`). `${{ secrets.GITHUB_TOKEN }}` works for same-account publishing. |
| `vcpkg-root` | no       | derived            | Path to vcpkg. Default resolution: `$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg`. |
| `vcpkg-commit` | no     | `""`               | Commit SHA (tag/branch also accepted) of `microsoft/vcpkg` to pin the local checkout to. Empty = use the runner image's bundled commit. See [Reproducibility](#reproducibility-pinning-vcpkg). |
| `mode`       | no       | `readwrite`        | `read` (consumer-only — won't publish) or `readwrite` (default — publishes on cache miss). |

## Outputs

| Name         | Description                |
|--------------|----------------------------|
| `feed-url`   | Resolved feed URL.         |
| `vcpkg-root` | Resolved vcpkg root path.  |

## Authentication and permissions

- The calling job needs `permissions: { contents: read, packages: write }`
  in publisher mode, or `packages: read` in consumer-only mode.
- For publishing within the **same GitHub account/org** as the calling
  repo: `${{ secrets.GITHUB_TOKEN }}` works out of the box.
- For **cross-account** publish or read: a Personal Access Token (PAT)
  with `write:packages` (or `read:packages`) is required.
- **Pull requests from forks**: `GITHUB_TOKEN` does not get
  `packages:write`, so push is rejected and the build falls back to
  source. Same behaviour as `actions/cache`.

## Platform support

Windows runners (`windows-latest`, `windows-2022`, etc.) only. vcpkg is
pre-installed at `C:\vcpkg` on GitHub-hosted Windows runners. Linux and
macOS are out of scope: `nuget.exe` requires Mono there, and binary
caching for Windows-targeted MSVC builds is the design centre. The
action exits with an error on non-Windows runners.

## Read-only consumer mode

If repo A publishes a feed and repo B wants to reuse it without ever
publishing, configure repo B like this:

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
  - run: vcpkg install --triplet=x64-windows-static-md libspatialite
    # Cache hit: download. Cache miss: build locally (NOT pushed).
```

## Why this vs `actions/cache`?

Most existing tutorials suggest caching `vcpkg/archives` with
`actions/cache`. That works but has structural issues:

| Property                                  | `actions/cache` | This action (NuGet) |
|-------------------------------------------|-----------------|---------------------|
| Cache hit granularity                     | tarball-wide    | per port            |
| Survives `vcpkg HEAD` updates             | ❌ all-miss     | ✅ unchanged ports hit |
| Survives test failures (post step)        | ❌ skipped save | ✅ port-by-port push |
| Eviction policy                           | 7 days idle     | persistent          |
| Cross-repository sharing (same owner)     | ❌              | ✅                  |

The NuGet approach scales better as the dependency graph grows.

## License

Dual-licensed under either:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

at your option.

Contributions intentionally submitted for inclusion in this work, as defined
in the Apache-2.0 license, shall be dual-licensed as above without any
additional terms or conditions.
