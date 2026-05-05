# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single GitHub **composite action** (`action.yml`) that wires vcpkg's binary
caching to a GitHub Packages NuGet feed in one `uses:` line. There is no
compiled source, no build step, no package manager — every change ships by
editing `action.yml` (and keeping the docs in sync).

Status: **pre-1.0**, single-maintainer Marketplace publish workflow. Default
to the smallest change that solves the problem; resist adding inputs,
abstractions, or fallbacks "just in case."

## Architecture: the 6-step env-var chain

`action.yml` is six sequential bash steps. They are not independent — each
later step depends on environment variables that earlier steps wrote to
`GITHUB_ENV`. Reordering or splitting steps without preserving this chain
will silently break the action.

1. **Resolve defaults** — validates `mode`, validates `RUNNER_OS=Windows`,
   resolves `feed-url` / `vcpkg-root`, and exports `VCPKG_BIN` to
   `GITHUB_ENV`. All later steps read `$VCPKG_BIN`.
2. **Verify vcpkg installation** — checks `$VCPKG_BIN` exists, exports
   `VCPKG_ROOT`.
3. **Fetch nuget.exe via vcpkg** — runs `vcpkg fetch nuget`, captures the
   path from the **last non-empty stdout line** (the command may emit
   progress lines first), exports `NUGET_EXE`.
4. **Configure NuGet source** — `nuget sources add` with
   `-StorePasswordInClearText` (required so vcpkg's separate process can
   later decrypt the credential — DPAPI would break that), then
   `setapikey`. Idempotent: removes any prior registration with the same
   name first.
5. **Export `VCPKG_BINARY_SOURCES`** — `clear;nuget,<feed>,<mode>`. The
   leading `clear` deliberately drops vcpkg's default local-files cache so
   the NuGet feed is the only source.
6. **vcpkg install** — only runs if `inputs.ports` is non-empty. Otherwise
   the caller runs `vcpkg install` themselves later in the job.

When editing, keep this chain intact and the env-var hand-off explicit.

## Platform: Windows-only by design

Step 1 hard-exits on non-Windows runners. This is intentional, not a TODO:
`nuget.exe` needs Mono on Linux/macOS, and the use case (caching MSVC-built
artefacts) is Windows-centric. Do not add Linux/macOS branches without an
explicit user request — it would expand scope significantly.

## Testing model

There is no local test harness. The only end-to-end verification is
`.github/workflows/self-test.yml` running on a real `windows-latest` runner
against a live GitHub Packages feed:

- `push` to `main` (paths: `action.yml`, the workflow itself) → publisher
  mode against `libspatialite` + `x64-windows-static-md`.
- `pull_request` → consumer (`mode: read`) only, because fork PRs cannot
  get `packages: write` on `GITHUB_TOKEN`.
- `workflow_dispatch` for ad-hoc smoke runs.

Local YAML edits cannot be meaningfully validated beyond syntax. After
non-trivial `action.yml` changes, expect the user to push and watch the
self-test, or trigger `workflow_dispatch` manually.

## Documentation: bilingual mirrors

`README.md` (English) and `README.ja.md` (Japanese) are translation pairs.
When updating one, update the other in the same change so they do not
drift. Keep examples in `examples/basic-usage.yml` consistent with the
Quick start snippet in both READMEs.

Docs and `action.yml` descriptions should stay **generic / reusable** —
no references to specific downstream consumer repositories, even as
examples.

## Things to avoid

- Tracking `.claude/` in git — it is `.gitignore`d on purpose (local AI
  tooling state, not part of the action).
- Adding "comparison to similar actions X / Y" sections to the README.
  "Why this design vs alternative" sections (e.g. NuGet vs `actions/cache`)
  are different and welcome.
- Skipping pre-commit hooks or signing flags. Investigate failures
  instead.
- Backwards-compat shims for inputs that have not yet shipped a v1 — the
  action is pre-1.0, so renaming/removing inputs is still cheap.
