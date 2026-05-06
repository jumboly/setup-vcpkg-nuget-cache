#Requires -Version 7.0
<#
.SYNOPSIS
Configure vcpkg to use a GitHub Packages NuGet feed as a binary cache.

.DESCRIPTION
Pins the local vcpkg checkout to a specific commit, registers a GitHub
Packages NuGet feed as a vcpkg binary cache backend, and exports the
necessary environment variables (VCPKG_ROOT and VCPKG_BINARY_SOURCES).

This single script is invoked both by the composite GitHub Action
(action.yml) and directly by developers on their local machine. The
intent is structural parity: there is one implementation, so CI and
local cannot drift.

.PARAMETER Token
GitHub token with packages:write (publish) or packages:read (consume).
In CI, secrets.GITHUB_TOKEN works for same-owner publishing; cross-owner
or local use requires a Personal Access Token.

.PARAMETER Mode
'read' (consumer-only) or 'readwrite' (default — publishes on cache miss).

.PARAMETER VcpkgCommit
Explicit microsoft/vcpkg commit SHA to pin to. Overrides ManifestPath
auto-detection. Tags and branches also work but SHAs are recommended
for reproducibility.

.PARAMETER ManifestPath
Path to vcpkg.json. Default: ./vcpkg.json. The script reads its
'builtin-baseline' field as the SHA when VcpkgCommit is not provided.
This is what makes vcpkg.json the single source of truth for both deps
and tool version.

.PARAMETER FeedUrl
NuGet feed URL. Default: GitHub Packages of the repository owner
(https://nuget.pkg.github.com/<owner>/index.json), where <owner> is
inferred from $env:GITHUB_REPOSITORY_OWNER or the -Owner parameter.

.PARAMETER FeedName
Internal NuGet source key. Default: 'github-packages'.

.PARAMETER VcpkgRoot
Path to vcpkg installation. Resolved in order: -VcpkgRoot,
$env:VCPKG_INSTALLATION_ROOT, $env:VCPKG_ROOT, then C:\vcpkg.

.PARAMETER Owner
GitHub account/org owning the NuGet feed. Used as the NuGet source
-Username and to derive the default FeedUrl. Defaults to
$env:GITHUB_REPOSITORY_OWNER (always set in GitHub Actions).

.EXAMPLE
# Local developer: read-only cache, deps declared in ./vcpkg.json
$env:GH_TOKEN = "ghp_..."
.\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read -Owner myname

.EXAMPLE
# Override SHA explicitly (classic mode users with no vcpkg.json)
.\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -VcpkgCommit 84bab45...
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Token,

    [ValidateSet('read', 'readwrite')]
    [string]$Mode = 'readwrite',

    [string]$VcpkgCommit = '',

    [string]$ManifestPath = './vcpkg.json',

    [string]$FeedUrl = '',

    [string]$FeedName = 'github-packages',

    [string]$VcpkgRoot = '',

    [string]$Owner = ''
)

$ErrorActionPreference = 'Stop'
# Native commands (git, nuget, bootstrap-vcpkg.bat) throw on non-zero
# exit. Avoids the per-call $LASTEXITCODE dance.
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version 3.0

function Write-MaskedSecret {
    param([string]$Value)
    if ($env:GITHUB_ACTIONS -eq 'true' -and $Value) {
        Write-Host "::add-mask::$Value"
    }
}

function Write-CacheEnv {
    # Dual write — to $GITHUB_ENV (so later CI steps see it) and to the
    # current process (so a local pwsh session is equivalent to a CI
    # step). Without the process write, the local caller's vcpkg
    # invocations would not see VCPKG_BINARY_SOURCES.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($env:GITHUB_ENV) {
        Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value"
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Write-CacheOutput {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Resolve-VcpkgRoot {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:VCPKG_INSTALLATION_ROOT) { return $env:VCPKG_INSTALLATION_ROOT }
    if ($env:VCPKG_ROOT) { return $env:VCPKG_ROOT }
    return 'C:\vcpkg'
}

function Resolve-Owner {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:GITHUB_REPOSITORY_OWNER) { return $env:GITHUB_REPOSITORY_OWNER }
    return ''
}

function Resolve-FeedUrl {
    param([string]$Explicit, [string]$Owner)
    if ($Explicit) { return $Explicit }
    if (-not $Owner) {
        throw "Cannot determine feed URL: pass -FeedUrl explicitly, or -Owner, or run inside GitHub Actions where GITHUB_REPOSITORY_OWNER is set."
    }
    return "https://nuget.pkg.github.com/$Owner/index.json"
}

function Resolve-Sha {
    param([string]$Explicit, [string]$ManifestPath)
    if ($Explicit) { return $Explicit }
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "vcpkg-commit was not specified and $ManifestPath does not exist. Provide -VcpkgCommit, or place a vcpkg.json with a 'builtin-baseline' field at the manifest path."
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    # Hyphenated key + StrictMode would throw on dotted access for a
    # missing field; PSObject.Properties[…] returns $null cleanly.
    $prop = $manifest.PSObject.Properties['builtin-baseline']
    if (-not $prop -or -not $prop.Value) {
        throw "$ManifestPath has no 'builtin-baseline' field. Either add one (recommended for cache stability) or pass -VcpkgCommit explicitly."
    }
    return $prop.Value
}

# Hard-fail on non-Windows: nuget.exe needs Mono elsewhere and the
# Windows-targeted MSVC binary cache use case is the design centre.
if (-not $IsWindows) {
    throw "This script supports Windows only."
}

Write-MaskedSecret -Value $Token

$resolvedRoot     = Resolve-VcpkgRoot -Explicit $VcpkgRoot
$resolvedOwner    = Resolve-Owner -Explicit $Owner
$resolvedFeedUrl  = Resolve-FeedUrl -Explicit $FeedUrl -Owner $resolvedOwner
$resolvedSha      = Resolve-Sha -Explicit $VcpkgCommit -ManifestPath $ManifestPath

Write-Host "vcpkg-root:   $resolvedRoot"
Write-Host "feed-url:     $resolvedFeedUrl"
Write-Host "feed-name:    $FeedName"
Write-Host "mode:         $Mode"
Write-Host "vcpkg-commit: $resolvedSha"

if (-not (Test-Path -LiteralPath $resolvedRoot)) {
    throw "vcpkg directory not found at $resolvedRoot. Bootstrap vcpkg before calling this script."
}
if (-not (Test-Path -LiteralPath (Join-Path $resolvedRoot '.git'))) {
    throw "$resolvedRoot is not a git tree (no .git/ found). Cannot pin to a SHA."
}

$vcpkgExe = Join-Path $resolvedRoot 'vcpkg.exe'

# Skip the ~30s fetch+checkout+bootstrap when the checkout is already
# at the requested commit and vcpkg.exe exists — the common warm-run
# case (re-running the script in the same shell, repeated CI runs on
# a runner that hasn't been refreshed). Resolve the requested ref
# (which may be a tag or branch, not a SHA) before comparing, so the
# short-circuit also fires when a tag is passed.
$currentHead  = $null
$targetCommit = $null
if (Test-Path -LiteralPath $vcpkgExe) {
    try {
        $currentHead  = (& git -C $resolvedRoot rev-parse HEAD).Trim()
        $targetCommit = (& git -C $resolvedRoot rev-parse --verify "$resolvedSha^{commit}").Trim()
    } catch { }
}

if ($targetCommit -and $currentHead -eq $targetCommit) {
    Write-Host "vcpkg already at $resolvedSha ($targetCommit); skipping fetch + checkout + bootstrap"
    $resolvedSha = $targetCommit
} else {
    # Full fetch: pinned SHAs may be on branches not tracked locally
    # yet (e.g. an older release commit not on master HEAD).
    Write-Host "Fetching latest history from origin"
    & git -C $resolvedRoot fetch --tags origin

    Write-Host "Checking out $resolvedSha (detached)"
    try {
        & git -C $resolvedRoot checkout --detach $resolvedSha
    } catch {
        throw "git checkout failed (is $resolvedSha a valid revision?): $_"
    }

    # Capture the resolved 40-char SHA so the action's vcpkg-commit
    # output is always a SHA, not a tag/branch name the caller passed.
    $resolvedSha = (& git -C $resolvedRoot rev-parse HEAD).Trim()

    # Re-bootstrap so vcpkg.exe matches the checked-out scripts.
    # Skipping this leaves the previous vcpkg.exe in place, which can
    # be ABI-incompatible with the new scripts/buildsystems (silent
    # failures or "unknown manifest field" errors at install time).
    $bootstrap = Join-Path $resolvedRoot 'bootstrap-vcpkg.bat'
    Write-Host "Running bootstrap-vcpkg.bat -disableMetrics"
    & $bootstrap -disableMetrics

    if (-not (Test-Path -LiteralPath $vcpkgExe)) {
        throw "vcpkg.exe not found at $vcpkgExe after bootstrap. Inspect log above."
    }
}

Write-Host "Fetching nuget.exe via vcpkg"
$fetchOutput = & $vcpkgExe fetch nuget
# vcpkg fetch nuget can print progress lines first; the actual path is
# the last non-empty line of stdout.
$nugetExe = $fetchOutput | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1
if (-not $nugetExe -or -not (Test-Path -LiteralPath $nugetExe)) {
    throw "vcpkg fetch nuget did not produce a usable path (got: '$nugetExe')"
}
Write-Host "nuget.exe: $nugetExe"

# Idempotent: drop any prior registration with the same name. The
# remove may fail (nothing to remove) — fine, the next add is what
# matters. Suppressed via *>$null since we don't want native-command
# error throwing here.
Write-Host "Removing prior NuGet source registration (if any)"
try { & $nugetExe sources remove -Name $FeedName *>$null } catch { }

# -StorePasswordInClearText is required so vcpkg (a separate process)
# can later decrypt the credential. DPAPI encryption would bind the
# secret to the user that ran 'sources add', breaking vcpkg's reads —
# silently in CI, mysteriously locally.
$nugetUsername = if ($resolvedOwner) { $resolvedOwner } else { 'vcpkg-cache-user' }
Write-Host "Adding NuGet source $FeedName -> $resolvedFeedUrl"
& $nugetExe sources add `
    -Name $FeedName `
    -Source $resolvedFeedUrl `
    -Username $nugetUsername `
    -Password $Token `
    -StorePasswordInClearText

Write-Host "Setting NuGet API key"
& $nugetExe setapikey $Token -Source $resolvedFeedUrl

# 'clear' resets vcpkg's default sources (which include the local
# files cache) so the NuGet feed is the only source. Drop 'clear' to
# keep the local files cache as a fallback.
$binarySources = "clear;nuget,$resolvedFeedUrl,$Mode"

Write-Host "Exporting VCPKG_ROOT=$resolvedRoot"
Write-CacheEnv -Name 'VCPKG_ROOT' -Value $resolvedRoot

Write-Host "Exporting VCPKG_BINARY_SOURCES=$binarySources"
Write-CacheEnv -Name 'VCPKG_BINARY_SOURCES' -Value $binarySources

Write-CacheOutput -Name 'feed-url'     -Value $resolvedFeedUrl
Write-CacheOutput -Name 'vcpkg-root'   -Value $resolvedRoot
Write-CacheOutput -Name 'vcpkg-commit' -Value $resolvedSha

Write-Host ""
Write-Host "Setup complete. vcpkg is pinned to $resolvedSha."
Write-Host "You can now run 'vcpkg install' (or build with VS / msbuild) to use the cache."
