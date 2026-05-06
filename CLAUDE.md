# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A GitHub **composite action** (`action.yml`) plus a matching
**PowerShell script** (`tools/Setup-VcpkgCache.ps1`) that together wire
vcpkg's binary cache to a GitHub Packages NuGet feed. The composite
action is a thin wrapper; the script is where the logic lives.

The same script is intended to be invoked **both from the action (in
CI) and directly from a developer's local PowerShell session**. This
structural parity — one implementation, two callers — is the point.
"Same behavior in CI and local" is what makes the cache hit rate work
across machines, and it's the property the design protects.

The action is **mode-agnostic**:

- The recommended path is **manifest mode**: caller has a `vcpkg.json`
  with `dependencies` + `builtin-baseline`; the action reads the SHA
  from `builtin-baseline` automatically and pins the vcpkg checkout to
  it. The caller invokes `vcpkg install` (or relies on VS auto-vcpkg
  integration via msbuild).
- **Classic mode** also works as a side-effect: the caller passes
  `vcpkg-commit:` explicitly to the action and skips `vcpkg.json`. The
  README mentions this as a fallback in one short subsection.

The action does **not** invoke `vcpkg install` itself. That's still
the caller's responsibility (or msbuild's, when VS integration is in
play).

Status: single-maintainer Marketplace publish workflow. There are no
existing v2 users to preserve compatibility for; that tag is being
retired in favor of v1. Default to the smallest change that solves
the problem; resist adding inputs, abstractions, or fallbacks "just
in case."

## Architecture

Two files, one logic stream:

```
action.yml                          # ~50 lines, calls the script
tools/Setup-VcpkgCache.ps1          # ~250 lines, all the actual work
```

### `tools/Setup-VcpkgCache.ps1`

Single PowerShell 7+ script. Parameters mirror the action inputs
(PascalCase locally, kebab-case in YAML):

- `-Token`         (required) GitHub token (PAT or `secrets.GITHUB_TOKEN`)
- `-Mode`          read | readwrite
- `-VcpkgCommit`   override SHA (else read from manifest)
- `-ManifestPath`  default `./vcpkg.json`
- `-FeedUrl`       default `https://nuget.pkg.github.com/<owner>/index.json`
- `-FeedName`      default `github-packages`
- `-VcpkgRoot`     default env-derived → `C:\vcpkg`
- `-Owner`         default `$env:GITHUB_REPOSITORY_OWNER`

Flow:

1. **Pre-flight**: Hard-fail on non-Windows. Mask `-Token` so it can't
   leak through later log lines.
2. **Resolve inputs**: vcpkg-root, owner, feed URL, SHA. The SHA
   resolution is what makes `vcpkg.json` the single source of truth:
   if `-VcpkgCommit` is empty, read `builtin-baseline` from the
   manifest. If neither is available, fail.
3. **Verify vcpkg checkout**: directory exists, has a `.git/`. We
   need a real git tree to pin.
4. **Pin to SHA**: `git fetch --tags origin` →
   `git checkout --detach <SHA>` → `bootstrap-vcpkg.bat -disableMetrics`.
   The bootstrap is **mandatory** — old `vcpkg.exe` against new scripts
   produces silent ABI mismatches or "unknown manifest field" errors.
5. **Fetch nuget.exe**: `vcpkg fetch nuget`. The path is the last
   non-empty line of stdout.
6. **Configure NuGet source**: `sources remove` (idempotent) then
   `sources add` with `-StorePasswordInClearText` (DPAPI would break
   vcpkg's separate-process reads) and `setapikey`.
7. **Export env vars**: writes both `VCPKG_ROOT` and
   `VCPKG_BINARY_SOURCES` to `$env:GITHUB_ENV` (CI) **and** to the
   current process environment (local). The dual write is what makes
   the script work identically in both contexts.

### `action.yml`

A single `pwsh` step that:

1. Validates `RUNNER_OS=Windows`
2. Calls `${{ github.action_path }}/tools/Setup-VcpkgCache.ps1` with
   parameters supplied via env vars (not via YAML expression
   substitution into the script body — this prevents PowerShell
   expression injection from a malicious input).
3. Outputs are written by the script directly to `$GITHUB_OUTPUT`.

When editing, do not push logic into `action.yml`. The wrapper should
stay a wrapper. If you need new behavior, add it in the script and
expose it as a new parameter.

## Platform: Windows-only by design

Both `action.yml` and the script hard-exit on non-Windows. This is
intentional, not a TODO: `nuget.exe` needs Mono on Linux/macOS, and
the use case (caching MSVC-built artefacts) is Windows-centric. Do not
add Linux/macOS branches without an explicit user request.

## Testing model

There is no local unit-test harness. The only end-to-end verification
is `.github/workflows/self-test.yml` running on a real `windows-latest`
runner against a live GitHub Packages feed. It covers two paths:

- **Through the composite action** (`uses: ./`): publisher mode on
  push/dispatch, consumer mode on PR.
- **Directly invoking the script** (`pwsh -File tools/Setup-VcpkgCache.ps1`)
  without the action wrapper. This is the local-developer code path;
  if the script grows action-only assumptions, this job catches it.

Both paths use `tests/manifest/vcpkg.json` as the fixture. Its
`builtin-baseline` is the SHA the action should auto-resolve to; the
read-only verify step compares it against `git rev-parse HEAD` in
`$VCPKG_ROOT` to confirm auto-resolution worked.

Local YAML/PowerShell edits cannot be meaningfully validated beyond
syntax. After non-trivial changes, expect to push and watch
self-test, or trigger `workflow_dispatch` manually.

## Documentation: bilingual mirrors

Two doc tiers, both bilingual:

- `README.md` / `README.ja.md` — reference + Quick start. Short.
  Links to the guide for explanations.
- `docs/vcpkg-guide.md` / `docs/vcpkg-guide.ja.md` — the educational
  guide. Why pinning matters, ABI hash explained, SHA selection,
  VS integration, triplet pitfalls, multi-solution patterns, classic
  mode, FAQ. Long, story-driven.

When updating EN, update JA in the same change. Same goes for the
guide. Examples in `examples/basic-usage.yml` should match the Quick
start in both READMEs.

Docs and `action.yml` descriptions should stay **generic / reusable** —
no references to specific downstream consumer repositories.

## Things to avoid

- Tracking `.claude/` in git — it is `.gitignore`d on purpose (local
  AI tooling state, not part of the action).
- Adding "comparison to similar actions X / Y" sections to the README.
  "Why this design vs alternative" sections (e.g. NuGet vs
  `actions/cache`) are different and welcome.
- Skipping pre-commit hooks or signing flags. Investigate failures
  instead.
- **Re-introducing classic-mode shortcuts** that have the action run
  `vcpkg install` itself (e.g. `ports`/`triplet` inputs). The action's
  responsibility is NuGet feed wiring + vcpkg pinning, full stop. The
  caller (or msbuild via VS integration) runs `vcpkg install`. Classic
  mode is supported only by exposing `vcpkg-commit` as an explicit
  override, not by the action doing the install itself.
- Putting logic into `action.yml`. The wrapper stays a wrapper; logic
  lives in `tools/Setup-VcpkgCache.ps1` so CI and local share a single
  implementation.
- Substituting workflow inputs directly into the inline `pwsh` script
  body via `${{ inputs.x }}`. Always pass through env vars to avoid
  PowerShell expression injection.
- Documenting features the action doesn't have, or assuming the
  caller's mode. The action is mode-agnostic; the README recommends
  manifest mode but doesn't enforce it.
