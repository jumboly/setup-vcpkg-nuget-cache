# Understanding vcpkg binary caching with this action

[日本語版はこちら / Japanese version](vcpkg-guide.ja.md)

This guide explains *why* this action is shaped the way it is, and what
you need to know about vcpkg to use it confidently. You don't need to
be a vcpkg expert to use the action — but if you've ever stared at a
40-character SHA and wondered "what am I supposed to do with this?",
this guide is for you.

It's longer than the README on purpose. The README tells you what
buttons to press; this guide tells you what's behind the buttons, so
you can debug the inevitable surprise without panicking.

## 1. What vcpkg actually is

If you're coming from `apt`, `yum`, `Homebrew`, `npm`, `cargo`, or
even `conan`, your mental model of a package manager is probably:

> A package manager downloads precompiled binaries from a central
> registry and drops them on your machine.

**vcpkg does not work like that.** This single fact explains almost
everything else about why this action exists.

### No central binary registry

There is no vcpkg.org server hosting `.lib` and `.dll` files for every
combination of platform, compiler version, and build option. The
`microsoft/vcpkg` GitHub repository contains **build recipes**, not
binaries. Every dependency you ask for is **compiled from source on
your machine** the first time you ask for it. (And the second time,
unless you've configured a binary cache — which is what this action
sets up.)

The reason for this design is the C++ ABI: a `libfoo.lib` built with
MSVC 19.40 at `/MD` is not interchangeable with one built with MSVC
19.41 at `/MT`, even though both came from libfoo's source. The
combinatorial explosion of "every compiler × every linkage × every
CRT × every feature flag" makes a central prebuilt-binary store
impractical. So vcpkg punts: ship the recipe, build it locally to
match exactly what your project needs.

### What's in the vcpkg repo

When you clone `microsoft/vcpkg` (or use the pre-installed `C:\vcpkg`
on a runner), you get:

```
vcpkg/
├── vcpkg.exe                # the tool itself (built by bootstrap-vcpkg.bat)
├── bootstrap-vcpkg.bat
├── ports/                   # one directory per package
│   ├── libspatialite/
│   │   ├── portfile.cmake   # build recipe
│   │   ├── vcpkg.json       # port metadata (version, deps)
│   │   └── *.patch          # any local patches to upstream source
│   └── ...                  # ~2500 ports
├── triplets/                # target descriptors (x64-windows, ...)
├── scripts/                 # build helpers, CMake integration
└── versions/                # "version → git tree SHA" index per port
```

That's it. No binary blobs. No registry queries. The repo IS the
package database.

### What `vcpkg install libfoo` actually does

When you run `vcpkg install libfoo`, the tool:

1. Reads `ports/libfoo/portfile.cmake` (the recipe).
2. Downloads upstream source — usually a tarball from
   `github.com/upstream/libfoo/archive/v1.2.3.tar.gz` — to a local
   downloads cache.
3. Verifies the SHA-512 of the downloaded source against what
   `portfile.cmake` says it should be.
4. Applies any patches in the port directory (most ports have none;
   some need MSVC-compatibility tweaks upstream hasn't accepted yet).
5. Configures the build for the active triplet (CMake or autotools or
   custom, depending on the port).
6. Compiles using MSVC.
7. Installs into `vcpkg/installed/<triplet>/`.
8. Recurses for transitive dependencies first.

For something like `libspatialite`, this transitive graph is 9–10
ports deep, totaling 15–40 minutes of compilation on a CI runner.

This is why we care so much about caching: every dependency is a
local build, and local builds are slow.

### Two ways to ask for packages

vcpkg supports two interaction styles:

**Classic mode** — pass packages on the command line:

```powershell
vcpkg install libfoo libbar --triplet=x64-windows-static-md
```

vcpkg uses whatever portfiles are in your local checkout's HEAD. No
declarative file in your project. Quick for ad-hoc experiments.
Downside: the dependency list lives in your build script (or your
shell history), not in the repo, so it drifts between machines and
between developers.

**Manifest mode** — declare what you need in `vcpkg.json`:

```json
{
  "name": "my-app",
  "dependencies": ["libfoo", "libbar"],
  "builtin-baseline": "84bab45d415d22042bd0b9081aea57f362da3f35"
}
```

Then run `vcpkg install` (no arguments). vcpkg reads the manifest from
the current directory, resolves versions against the
`builtin-baseline` SHA, and installs into a project-local
`vcpkg_installed/` folder.

**Manifest mode is the modern default**, and it's what this action
recommends. The `builtin-baseline` field gives you per-port version
pinning that survives across machines, which is half of what makes
local + CI cache parity possible. (The other half is pinning the
vcpkg checkout itself, which the action handles.)

Classic mode still works — see [chapter 11](#11-using-classic-mode) —
but you give up the declarative-deps + version-pin benefits.

## 2. Why caching matters

A typical `vcpkg install libspatialite` cold-builds nine or ten
transitive dependencies (proj, geos, sqlite3, libcurl, libxml2, ...).
On a `windows-latest` runner that's 15–40 minutes of CI time. Every
push. Every PR. Every nightly job.

For a one-off project that's annoying. For a team that pushes 50
commits a day across half a dozen repos, it's death by a thousand
five-minute coffees — your CI bill grows, your feedback loop slows
down, and people start avoiding pushes "just for a small fix" because
they don't want to wait.

vcpkg has a built-in answer:
[binary caching](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching).
The first time vcpkg builds a port for a given configuration, it
stashes the compiled artefact. Next time the same configuration is
asked for, it pulls the artefact instead of rebuilding. Cache hits
turn 25-minute builds into 90-second downloads.

The question is: where do you stash the artefacts?

### The death of `x-gha`

For a while, the popular answer was the `x-gha` backend, which used
GitHub's Actions Cache (the same store `actions/cache` writes to).
Microsoft removed `x-gha` in late 2024 because Actions Cache wasn't
designed for vcpkg's access patterns and the integration kept breaking.

The remaining well-supported backends are NuGet feeds, Azure Blob
Storage, and a few others. Of those, **NuGet on GitHub Packages** is
the natural fit if your code lives on GitHub: the storage is free
within your account quota, the access tokens are the same ones you
already use for the repo, and there's no separate cloud account to
manage.

This action wires that backend up.

## 3. What is an "ABI hash"?

vcpkg's binary cache key isn't "the port's version number". If it
were, the cache would be wrong half the time — `libfoo 1.2.3` built
with MSVC 19.40 isn't binary-compatible with `libfoo 1.2.3` built with
MSVC 19.41, even though the version is identical.

So vcpkg computes an **ABI hash** for each port build. The hash mixes
together everything that could change the resulting `.lib` / `.dll`:

- Compiler version (the exact MSVC build number)
- Port version (e.g. `libspatialite 5.1.0`)
- The contents of `portfile.cmake` (build instructions)
- The contents of the triplet file (`x64-windows-static-md.cmake` etc.)
- The contents of vcpkg's build scripts (`scripts/buildsystems/...`)
- The ABI hashes of every direct dependency (recursively)
- Build options and feature flags

If any one byte in any one of these inputs changes, the ABI hash
changes, and you get a cache miss. Conversely, if all of them are
identical between two machines, you get a cache hit — even across
different runners, different operating systems' build environments,
or your laptop versus CI.

This is *good*. It's why vcpkg's cache is reliable: a hit truly means
the binary you're about to download was built from the same inputs
yours would have been.

It's also *brittle*: it means tiny invisible changes can blow up your
cache hit rate, and figuring out *why* requires understanding what
controls those inputs.

## 4. Why you have to "pin"

The `windows-latest` runner image ships a pre-installed vcpkg at
`C:\vcpkg`. Convenient. But GitHub refreshes runner images every
**~2 weeks**, and when they do, that vcpkg checkout gets bumped to a
newer commit — which means newer portfiles, newer triplet files,
newer build scripts.

Here's a story.

> **Monday.** A developer pushes a feature. CI runs. `libspatialite`
> cold-builds in 25 minutes. The artefact gets uploaded to the NuGet
> feed with ABI hash `aaaa...`.
>
> **Tuesday morning.** GitHub rolls out a new runner image. The
> bundled vcpkg is now `2025.12.12` (it was `2025.10.01` yesterday).
> The triplet file `x64-windows-static-md.cmake` got reformatted —
> not semantically, just whitespace. Even so: different bytes,
> different ABI hash.
>
> **Tuesday afternoon.** Same developer pushes a one-line README fix.
> CI runs. vcpkg computes ABI hash `bbbb...` for libspatialite. The
> NuGet feed has `aaaa...`, not `bbbb...`. Cache miss. 25-minute cold
> build. Again.
>
> **Wednesday.** Cold build. **Thursday.** Cold build.
>
> Now there are two libspatialite nupkgs in the feed (`aaaa` and
> `bbbb`), neither getting reused, both filling up storage. The
> developer concludes "this caching thing doesn't actually work" and
> rips it out.

The fix is to **pin vcpkg's checkout to a specific commit SHA**, so
that the ports tree, triplet files, scripts, and `vcpkg.exe` are
identical across runs — no matter what the runner image does
underneath.

## 5. `builtin-baseline` vs `vcpkg-commit`

vcpkg has two adjacent concepts here. They sound similar but pin
different things, and the relationship matters.

### `builtin-baseline` (a field in your `vcpkg.json`)

```json
{
  "name": "my-app",
  "dependencies": ["libspatialite"],
  "builtin-baseline": "84bab45d415d22042bd0b9081aea57f362da3f35"
}
```

This SHA pins **port versions**. When vcpkg resolves your dependency
graph in manifest mode, it walks the ports tree at this SHA (via git
plumbing) to look up which version of `libspatialite` is registered
there, and uses that version's `portfile.cmake` to build.

So `builtin-baseline` controls *what version of each port* you get,
and *what build instructions* are used.

### `vcpkg-commit` (an input to this action)

This pins the **whole vcpkg checkout** — `vcpkg.exe`, the
`triplets/*.cmake` files, and the `scripts/buildsystems/*` files. The
action does this by running:

```
git fetch --tags origin
git checkout --detach <SHA>
bootstrap-vcpkg.bat -disableMetrics
```

inside the vcpkg root directory. The whole working tree is rewritten
to that SHA's snapshot, and `vcpkg.exe` is rebuilt from that SHA's
sources.

So `vcpkg-commit` controls *the tool itself plus the triplets and
build scripts*.

### Why both

Recall that the ABI hash is computed from `portfile + triplet +
scripts + dependencies`. `builtin-baseline` covers the port + portfile
half. `vcpkg-commit` covers the triplet + scripts + tool half.
**You need both pinned for the ABI hash to be stable.**

Pinning only `builtin-baseline` while leaving the tool unpinned is the
Tuesday-morning story above: same port versions, but new triplets =
new ABI hash = cache miss.

### How v1 of this action handles it

Here's the trick: **v1 reads `builtin-baseline` from your `vcpkg.json`
and uses that same SHA for `vcpkg-commit` automatically**. You write
the SHA in one place (`vcpkg.json`); both halves of the pin happen
together. There's no second SHA to drift.

```yaml
# That's it. No vcpkg-commit input needed.
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

If you want to override (for example, you don't keep a `vcpkg.json` at
all), pass `vcpkg-commit:` explicitly. That path also works — see
[chapter 11](#11-using-classic-mode).

## 6. How to pick a SHA

The vcpkg repo is enormous and changes every day. Most commits on
`master` are individual port updates, and a typical port update
touches only one or two `versions/*.json` files. So almost any SHA
"works", but the question is: which ones leave you with a coherent,
internally-consistent ports tree?

**Use a release tag SHA.** vcpkg cuts release tags every couple of
months (named like `2025.12.12` — year.month.day). Each release tag
is the result of running internal CI across the whole ports tree;
all the ports work together at that point. Master HEAD doesn't have
that guarantee — at any given moment, port A might have updated to
require a feature that port B hasn't merged support for yet.

Two ways to find a release SHA:

**From the browser:**
[microsoft/vcpkg releases](https://github.com/microsoft/vcpkg/releases).
Pick the most recent. The page shows the commit SHA next to the tag —
copy the 40 characters.

**From the shell:**

```bash
git ls-remote --tags https://github.com/microsoft/vcpkg.git \
  | grep -E 'refs/tags/[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' \
  | tail -5
# 84bab45d415d22042bd0b9081aea57f362da3f35	refs/tags/2025.12.12
# ...
```

The leftmost column is the SHA. The most recent release is at the
bottom. Copy and paste into your `vcpkg.json`'s `builtin-baseline`.

### When to bump

Pinning is opt-in stagnation. Until you change the SHA, your build
keeps using the same ports forever. To take a newer snapshot:

1. Pick a newer release SHA (same procedure).
2. Update `builtin-baseline` in `vcpkg.json`. Commit.
3. The next CI run cold-builds against the new ports tree and pushes
   fresh nupkgs to your feed. Subsequent runs hit cache as before.

Plan to bump every few months, or when you need a port version that
landed upstream after your current pin. Don't bump constantly — every
bump is a one-time cold build.

## 7. Visual Studio integration

If you build with Visual Studio (or msbuild on the command line) and
your projects target C++ with `.vcxproj`, you can get **vcpkg to
auto-install dependencies as part of the build**. You don't run
`vcpkg install` manually. msbuild does it for you, finds the right
`vcpkg.json`, and links the resulting libraries into your project.

For this to work, three things need to be true:

1. **vcpkg integration is enabled.** Modern way: just have
   `VCPKG_ROOT` set in the environment when VS or msbuild runs.
   VS 2022 and recent msbuild versions auto-detect it. (Old way:
   `vcpkg integrate install` which writes machine-wide config.)
2. **`vcpkg.json` is reachable from your `.vcxproj`.** msbuild walks
   parent directories from the `.vcxproj` location until it finds a
   `vcpkg.json`. Place it at your solution directory (or repo root)
   and all projects under it inherit.
3. **`VCPKG_BINARY_SOURCES` is set in the environment.** This is
   what tells vcpkg "use the NuGet feed for cache". Without it,
   auto-install still works but builds from source every time.

The action sets both `VCPKG_ROOT` and `VCPKG_BINARY_SOURCES` for you.
So in CI, the workflow can be:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
- name: Build
  run: msbuild MyApp.sln /p:Configuration=Release /p:Platform=x64
  # msbuild auto-runs vcpkg install. No explicit step needed.
```

And locally:

```powershell
$env:GH_TOKEN = "ghp_..."
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# In the same shell:
devenv .\MyApp.sln    # Open VS. Press F7 to build. vcpkg auto-installs.
```

The cache hits "for free" — no developer action required beyond the
one-time PowerShell setup per shell session.

## 8. Triplets

A **triplet** tells vcpkg what to build for: architecture, OS,
linkage, and CRT. Some common ones:

| Triplet                  | Meaning |
|--------------------------|---------|
| `x64-windows`            | 64-bit Windows, **DLLs** (each library is a separate `.dll`) |
| `x64-windows-static`     | 64-bit Windows, **static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64-bit Windows, **static `.lib`** + **dynamic CRT** (`/MD`) — typical for VS-built apps that ship as a single `.exe` |
| `arm64-windows`          | ARM64 Windows, DLLs |
| `x86-windows`            | 32-bit Windows, DLLs |

### The VS auto-triplet pitfall

When VS triggers vcpkg auto-install based on the build configuration,
it picks the triplet from the MSBuild `Platform` property:

| MSBuild Platform | Default triplet  |
|------------------|------------------|
| `x64`            | `x64-windows`    |
| `Win32`          | `x86-windows`    |
| `arm64`          | `arm64-windows`  |

Note: **defaults to DLL builds**. If you want static-lib builds with
dynamic CRT (`x64-windows-static-md`), tell VS explicitly in your
`.vcxproj`:

```xml
<PropertyGroup Label="Vcpkg">
  <VcpkgEnabled>true</VcpkgEnabled>
  <VcpkgTriplet Condition="'$(Platform)'=='x64'">x64-windows-static-md</VcpkgTriplet>
</PropertyGroup>
```

Without this, you'll get DLL builds, and downstream linking errors
("unresolved external") because your application expected static
libs. Easy mistake; easy fix once you know.

If unsure which triplet to use: `x64-windows-static-md` is the
mainstream choice for VS-built apps that ship as a single
redistributable `.exe`.

## 9. Multi-solution repos

Real codebases often have several solutions sharing a repo. There are
two clean patterns; the action supports both.

### Pattern A: one `vcpkg.json` at the repo root

```
repo/
├── vcpkg.json              ← union of all solutions' deps + baseline
├── solutionA/solutionA.sln
└── solutionB/solutionB.sln
```

Simple. Every project under the repo finds the same `vcpkg.json` via
parent-directory traversal. One `builtin-baseline` to manage. Choose
this when most solutions share most of their dependencies.

### Pattern B: per-solution `vcpkg.json`

```
repo/
├── solutionA/
│   ├── vcpkg.json          (deps for A, baseline: SHA-X)
│   └── solutionA.sln
└── solutionB/
    ├── vcpkg.json          (deps for B, baseline: SHA-X ← same SHA!)
    └── solutionB.sln
```

Each solution declares its own deps. Choose this when solutions are
loosely related and you want each to install only what it actually
uses.

### Why all `builtin-baseline` values should match

The vcpkg checkout (`C:\vcpkg`) is a single git working tree, pinned
to one SHA. Within one CI job, you cannot have it at two SHAs at
once. So:

- If every `vcpkg.json` has `builtin-baseline: SHA-X`, the action
  pins the checkout to SHA-X, and ABI hashes line up perfectly.
- If `vcpkg.json` files have different baselines, vcpkg still works
  (it does git-tree traversal to find each baseline's portfiles), but
  the action only pins the checkout to one SHA — meaning triplet and
  script bytes are common across solutions while portfile bytes
  differ. The cache still works, but maintenance is painful (you have
  multiple SHAs to bump in lockstep).

Recommendation: **pick one SHA for the whole repo and put it in every
`vcpkg.json`**. When you bump the version, bump them all in one PR.

### Calling the action

Once per job is enough. The action's effect (pin + NuGet feed +
`VCPKG_BINARY_SOURCES`) is global to the job:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    manifest-path: solutionA/vcpkg.json    # any vcpkg.json with the SHA
- run: msbuild solutionA/solutionA.sln /p:Platform=x64
- run: msbuild solutionB/solutionB.sln /p:Platform=x64
```

If your `vcpkg.json` lives at the repo root, you can omit
`manifest-path`.

## 10. How CI and local share the same cache

Cache hits across machines require the ABI hash to match. The hash
includes the compiler version, port version, portfile, triplet,
scripts, and dependency hashes. To make those match between your
laptop and a CI runner:

- **Compiler version**: install the same MSVC version locally that CI
  uses. (Or accept that some ports may rebuild locally — usually only
  the leaf-level project, since transitive deps' MSVC dependence is
  weaker.)
- **Port version + portfile**: handled by `builtin-baseline` in
  `vcpkg.json`. Same SHA → same portfile bytes everywhere.
- **Triplet + scripts + vcpkg.exe**: handled by pinning the vcpkg
  checkout. The action does this in CI; the same PowerShell script
  does it locally.

This is why the action and the local PowerShell setup are **literally
the same code**. `tools/Setup-VcpkgCache.ps1` is what runs in CI, and
it's what runs on your laptop. There is no second implementation that
might drift.

The local flow:

```powershell
# One-time per shell session
$env:GH_TOKEN = "ghp_..."           # PAT with read:packages (or write)
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# After this, in the same session, you can use vcpkg as normal:
vcpkg install                       # cache hit if you build the same triplet as CI
```

If you want it permanent, set `VCPKG_BINARY_SOURCES` in your
PowerShell profile, and re-run the script whenever the `vcpkg.json`
SHA changes (the script will re-pin and re-bootstrap).

## 11. Using classic mode

If you don't want a `vcpkg.json` — for example, you have an existing
build script that calls `vcpkg install libfoo libbar
--triplet=x64-windows-static-md` directly — the action still works.
Just provide the SHA explicitly:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
- run: vcpkg install libfoo libbar --triplet=x64-windows-static-md
```

Locally:

```powershell
.\tools\Setup-VcpkgCache.ps1 `
    -Token $env:GH_TOKEN `
    -Mode read `
    -VcpkgCommit 84bab45d415d22042bd0b9081aea57f362da3f35
```

You lose the local/CI parity benefit of having `vcpkg.json` declare
both deps and the SHA in one place, but caching still works fine.

We **recommend manifest mode** (with a `vcpkg.json`) for any project
where multiple developers and CI all need to build the same way —
which is most projects. Classic mode is a graceful fallback for
existing setups, ad-hoc scripts, and small experiments.

## 12. Common misconceptions

**"If I have a `vcpkg.json`, my build is reproducible."**

Almost. `vcpkg.json` pins port versions, but only if it has a
`builtin-baseline`. Without that field, vcpkg uses whatever versions
are in your local checkout's HEAD — which depends on when you last
`git pull`ed in vcpkg. Add the baseline.

**"The runner image already has vcpkg, so caching is just gravy."**

The runner image's vcpkg gets bumped every two weeks. Without
pinning, every bump is a cache wipe (different triplet bytes →
different ABI hashes). The first build after a runner refresh will
cold-build everything, even if your `builtin-baseline` is unchanged.

**"`secrets.GITHUB_TOKEN` is enough for local development too."**

No — `GITHUB_TOKEN` is a CI-only secret, generated per workflow run
and unavailable on your laptop. There are two practical ways to get a
token locally:

1. **Borrow GitHub CLI's token.** If you've already run `gh auth login`,
   `gh auth token` returns the OAuth token. The catch: by default
   `gh auth login` does not include `read:packages` / `write:packages`
   scopes. Add them once:

   ```powershell
   gh auth refresh -s read:packages              # consumer
   gh auth refresh -s read:packages,write:packages   # publisher
   ```

   Then in any shell:

   ```powershell
   .\tools\Setup-VcpkgCache.ps1 -Token (gh auth token) -Mode read
   ```

2. **Generate a classic Personal Access Token (PAT).** Go to
   [github.com/settings/tokens](https://github.com/settings/tokens)
   → Tokens (classic) → Generate new token. Pick `read:packages` (or
   `write:packages`) as the scope. Treat the token like a password —
   keep it in environment variables, a credential manager, or a
   `.gitignore`d `.env.local`. Never commit it.

   Note: **fine-grained PATs are not reliable for GitHub Packages**
   — they were never fully wired up, especially against organization
   feeds. Use classic PATs.

**"`mode: read` will accidentally publish to the feed."**

It won't. `read` mode disables publishing — on a cache miss, the
build still happens locally, but the resulting `.nupkg` is not pushed
upstream. This is the right mode for fork PRs (which can't get
`packages: write` anyway) and for repos that should consume but
never publish.

**"If a port build fails, my cache is corrupted."**

It isn't. vcpkg pushes a port to the cache only after a successful
build. Failed builds leave the cache untouched.

**"My friend's project pushes to the same NuGet feed, will I see
their builds?"**

Only if you point `feed-url` at their account/org's feed and have
read permission there. By default the action targets the calling
repo's owner's feed (`https://nuget.pkg.github.com/<owner>/index.json`).
Cross-account sharing requires a PAT with `read:packages` for the
other owner.

---

If something here didn't match your experience, or you found a sharp
edge that wasn't covered, [open an issue](https://github.com/jumboly/setup-vcpkg-nuget-cache/issues) —
this guide should grow with the surprises real users hit.
