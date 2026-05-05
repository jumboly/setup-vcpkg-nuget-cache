# setup-vcpkg-nuget-cache

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[日本語版 README はこちら / Japanese README](README.ja.md)

A GitHub Action that wires up [vcpkg][vcpkg]'s binary cache to your
account's [GitHub Packages][github-packages] NuGet feed, so Windows +
Visual Studio CI builds reuse prebuilt binaries instead of rebuilding
dependencies from source on every push.

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages

## Who this is for

You're working on a C++ project (or a Rust / .NET project that depends on
C++ libraries) that:

- builds on **Windows** with **Visual Studio / MSVC**, and
- uses **vcpkg in manifest mode** (a `vcpkg.json` file in your repo
  declaring dependencies), and
- has GitHub Actions CI that currently rebuilds those libraries from
  source on every push (15–40 minutes per run for non-trivial graphs).

If you're using vcpkg in classic mode (`vcpkg install <port>` directly,
no manifest), see [Migrating to manifest mode](#migrating-to-manifest-mode).

## What it does

vcpkg has a built-in feature called [binary caching][vcpkg-binarycaching]:
once vcpkg has built a library for a given configuration, it can stash
the compiled artefacts and reuse them next time. One supported backend is
a NuGet feed — and GitHub Packages provides a free NuGet feed scoped to
your GitHub account.

Wiring vcpkg to a GitHub Packages NuGet feed in CI normally takes ~20
lines of YAML (`vcpkg fetch nuget` → `nuget sources add` → `setapikey` →
`VCPKG_BINARY_SOURCES`). **This action collapses all of that to a single
`uses:` line.** You then run `vcpkg install` yourself in manifest mode
and get cache hits automatically.

[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

## Quick start

Two pieces. First, put a `vcpkg.json` at your repo root (or wherever you
prefer to run `vcpkg install` from):

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

The `builtin-baseline` is a `microsoft/vcpkg` commit SHA; it pins the
versions of every port your build resolves to. See
[Picking a baseline SHA](#picking-a-baseline-sha) for how to choose one.

Second, in your GitHub Actions workflow:

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # required so the job can publish to GitHub Packages
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          # Recommended: same SHA as your vcpkg.json's builtin-baseline.
          vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35

      - name: Install vcpkg dependencies
        run: vcpkg install --triplet=x64-windows-static-md
        # Reads ./vcpkg.json. Cache hit: download from NuGet. Cache miss:
        # build locally and (in publisher mode) push the resulting nupkg.

      - name: Build
        run: cmake --preset windows-msvc && cmake --build out
```

What you'll see in the Actions log:

- **First run** (cold cache): `vcpkg install` builds your dependencies
  from source (~25 min for `libspatialite` + transitive deps), then
  uploads each built port to GitHub Packages.
- **Subsequent runs** (warm cache): vcpkg downloads prebuilt `.nupkg`
  files instead of building. Typically 1–2 minutes total.

GitHub-hosted `windows-latest` already has vcpkg pre-installed at
`C:\vcpkg`, so you don't need to bootstrap it.

## Reproducibility: pin vcpkg

Manifest mode's `builtin-baseline` already pins **port versions**. This
action's `vcpkg-commit` input pins the **vcpkg tool itself** (vcpkg.exe,
triplets, scripts). Setting them to the same SHA guarantees that CI uses
the exact tool version that was tested against your chosen ports tree:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
```

When `vcpkg-commit` is set, the action runs `git fetch && git checkout
<sha>` in `vcpkg-root` and re-bootstraps `vcpkg.exe`. Tags and branch
names also work but commit SHAs are recommended.

If you skip `vcpkg-commit`, you get whatever vcpkg the runner image
ships, which is refreshed roughly every two weeks — your tool can drift
out of sync with your `builtin-baseline` and emit version-resolution
warnings or errors. Strongly recommended to set both.

### Picking a baseline SHA

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

Use the same SHA for both `builtin-baseline` (in `vcpkg.json`) and
`vcpkg-commit` (in your workflow).

### Upgrading

Pinning is opt-in stagnation: until you change the SHA, your build keeps
using the old vcpkg / ports. To take a newer snapshot:

1. Pick a new SHA.
2. Update **both** `vcpkg.json`'s `builtin-baseline` **and** the workflow's
   `vcpkg-commit:` to that SHA. Commit.
3. The next CI run cold-builds against the new ports tree and publishes
   fresh nupkgs to your feed.

Plan to bump it every few months, or when you need a port version that
landed upstream after your current pin.

## Triplets

A *triplet* tells vcpkg what to build for: architecture + OS + linkage +
CRT. Most VS-built C++ projects pick one of:

| Triplet                  | Meaning |
|--------------------------|---------|
| `x64-windows`            | 64-bit Windows, **DLLs** (each library is a separate `.dll`) |
| `x64-windows-static`     | 64-bit Windows, **static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64-bit Windows, **static `.lib`** + **dynamic CRT** (`/MD`) — typical for VS-built apps that need a single redistributable `.exe` |

If unsure, start with `x64-windows-static-md`. For ARM64 builds, replace
`x64` with `arm64`. Pass it to your own `vcpkg install --triplet=...`
step (the action does not run vcpkg install for you).

## Verifying it works

After the first successful run:

1. Visit `https://github.com/<your-account>?tab=packages`. You should see
   the ports declared in `vcpkg.json` (and their transitive dependencies)
   listed as NuGet packages.
2. Re-run the workflow. The `vcpkg install` step should finish in 1–2
   minutes, and the vcpkg log lines will switch from `Building from
   source` to messages about restoring from the NuGet feed.

## Common errors

| Symptom | Cause / fix |
|---------|-------------|
| `error: While loading manifest ...: ...` | Your `vcpkg.json` is malformed or missing `builtin-baseline`. Add a baseline SHA. |
| `error: ... could not find baseline ...` | The `builtin-baseline` SHA in `vcpkg.json` is unknown to the local vcpkg checkout. Set `vcpkg-commit:` in the workflow to the same SHA. |
| `401 Unauthorized` when the action tries to push | The job lacks `packages: write` permission. Add the `permissions:` block from the Quick start. |
| All ports rebuilding on what should be a warm run | Either the runner image's MSVC / Windows SDK was upgraded, or you bumped `builtin-baseline` / `vcpkg-commit`. The first you cannot avoid; the second is intentional — keep the SHAs stable for cache stability. |
| Pull request from a fork: push fails | Expected. `GITHUB_TOKEN` from fork PRs cannot get `packages: write` for security reasons. Either gate publishing behind `if: github.event.pull_request.head.repo.full_name == github.repository`, or accept the cold build for fork PRs. |

## Inputs

| Name           | Required | Default            | Description |
|----------------|----------|--------------------|-------------|
| `token`        | **yes**  | —                  | GitHub token with `packages:write` (or `:read` for `mode: read`). `${{ secrets.GITHUB_TOKEN }}` works for same-account publishing. |
| `vcpkg-commit` | no       | `""`               | Commit SHA (tag/branch also accepted) of `microsoft/vcpkg` to pin the local checkout to. Strongly recommended; should match your `vcpkg.json` `builtin-baseline`. |
| `feed-url`     | no       | derived            | NuGet feed URL. Default: `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json` (your account). |
| `feed-name`    | no       | `github-packages`  | Internal NuGet source key. Rarely changed. |
| `vcpkg-root`   | no       | derived            | Path to vcpkg. Default resolution: `$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg`. |
| `mode`         | no       | `readwrite`        | `read` (consumer-only — won't publish) or `readwrite` (default — publishes on cache miss). |

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
  - uses: jumboly/setup-vcpkg-nuget-cache@v2
    with:
      mode: read
      feed-url: https://nuget.pkg.github.com/<publisher-account>/index.json
      token: ${{ secrets.GITHUB_TOKEN }}
      vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
  - run: vcpkg install --triplet=x64-windows-static-md
    # Cache hit: download. Cache miss: build locally (NOT pushed).
```

`vcpkg.json` (with `builtin-baseline` matching `vcpkg-commit`) lives in
the consumer repo as usual.

## Migrating to manifest mode

If your project currently runs `vcpkg install <port>` from a build
script or `actions/cache` setup, switch to manifest mode in three steps:

1. Add a `vcpkg.json` at your repo root listing the ports you currently
   pass on the command line. Set `builtin-baseline` to a recent
   `microsoft/vcpkg` release SHA.
2. Replace your `vcpkg install <port> ...` invocations with `vcpkg
   install` (no port arguments — vcpkg reads `vcpkg.json`).
3. Use this action with the same SHA as `vcpkg-commit`.

The result builds the same ports but with explicit version pinning and
local/CI parity (a developer running `vcpkg install` on their laptop
gets the same versions CI does).

## Why this vs `actions/cache`?

Most existing tutorials suggest caching `vcpkg/archives` with
`actions/cache`. That works but has structural issues:

| Property                                  | `actions/cache` | This action (NuGet) |
|-------------------------------------------|-----------------|---------------------|
| Cache hit granularity                     | tarball-wide    | per port            |
| Survives `builtin-baseline` updates       | ❌ all-miss     | ✅ unchanged ports hit |
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
