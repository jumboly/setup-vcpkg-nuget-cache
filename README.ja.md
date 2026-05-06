# setup-vcpkg-nuget-cache

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[English README](README.md)

vcpkg の binary cache を [GitHub Packages][github-packages] NuGet feed
に配線する GitHub Action と、対になる手元用 PowerShell スクリプト。
**CI とローカルで同じコードパスが流れる** ので、両環境で cache hit が
ズレなく動きます。

[github-packages]: https://github.com/features/packages

## 何をする action か

action は 1 step で 3 つのことを行います:

1. vcpkg の checkout を特定の commit SHA に pin します — `vcpkg.json`
   の `builtin-baseline` から自動取得、または明示指定。これによって
   vcpkg がキャッシュ key として使う ABI hash が安定し、`windows-latest`
   runner image の更新でキャッシュが無効化されるのを防げます。
2. GitHub Packages NuGet feed を vcpkg の binary source として登録。
3. `VCPKG_ROOT` と `VCPKG_BINARY_SOURCES` を export し、後続の step (や
   Visual Studio の auto-vcpkg integration) が cache を自動的に使える
   ようにします。

同じロジックは `tools/Setup-VcpkgCache.ps1` として同梱されており、
ローカルの PowerShell session から直接呼び出せます — [ローカル開発](#3-ローカル開発)
を参照。

vcpkg の binary caching が初めての方は **[まず vcpkg ガイドを読む](docs/vcpkg-guide.ja.md)** ことを
強くお勧めします ([English](docs/vcpkg-guide.md))。各入力の *なぜ* を
図と失敗事例とともに解説しています。

## クイックスタート

### 1. リポジトリに `vcpkg.json` を置く

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

`builtin-baseline` は `microsoft/vcpkg` のリリースタグの commit SHA。
どれを選べばいいか迷ったら ガイドの [SHA の選び方](docs/vcpkg-guide.ja.md#6-sha-の選び方) を参照。

### 2. workflow に action を組み込む

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # GitHub Packages へ publish するため
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Build
        run: msbuild MyApp.sln /p:Configuration=Release /p:Platform=x64
        # VS integration により msbuild が `vcpkg install` を自動実行
        # cache hit: download / cache miss: build + nupkg push
```

これだけ。`vcpkg-commit` 入力は不要 — action が `vcpkg.json` の
`builtin-baseline` から SHA を読み取ります。

VS integration を使わない場合は明示的に `vcpkg install` を実行:

```yaml
      - run: vcpkg install --triplet=x64-windows-static-md
```

Actions ログでの見え方:

- **初回 run (cold cache)**: `vcpkg install` が依存をソースから build
  (libspatialite + transitive deps で ~25 分)、終了時に各 port を
  GitHub Packages へ upload。
- **2 回目以降 (warm cache)**: vcpkg がビルド済み `.nupkg` を download。
  通常 1〜2 分程度で全 step 完了。

### 3. ローカル開発

`secrets.GITHUB_TOKEN` は CI 専用 — 手元では Personal Access Token か
`gh` CLI の token を使います。shell session ごとに 1 回:

```powershell
# 簡単: GitHub CLI の token を借りる (1 回だけ: gh auth refresh -s read:packages)
.\tools\Setup-VcpkgCache.ps1 -Token (gh auth token) -Mode read

# または: classic PAT (github.com/settings/tokens から read:packages 付きで生成)
$env:GH_TOKEN = "ghp_..."
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# 同じ shell で:
vcpkg install                    # GitHub Packages feed から cache hit
# あるいは VS で .sln を開いて build を押すだけでも同じ効果
```

スクリプトをリポジトリに取り込む (1 回だけ):

```powershell
New-Item -ItemType Directory -Force -Path tools | Out-Null
Invoke-WebRequest `
    -Uri https://raw.githubusercontent.com/jumboly/setup-vcpkg-nuget-cache/v1/tools/Setup-VcpkgCache.ps1 `
    -OutFile tools/Setup-VcpkgCache.ps1
```

commit する。action のメジャーバージョンを上げたときは再取得。

## Inputs

| 名前            | 必須   | デフォルト                | 説明 |
|-----------------|--------|----------------------------|------|
| `token`         | **必須** | —                        | GitHub token (publish 用は `packages:write`、consume 用は `:read`)。same-owner publish なら `${{ secrets.GITHUB_TOKEN }}` で十分 |
| `mode`          | 任意   | `readwrite`                | `read` (consume 専用) / `readwrite` (cache miss 時に publish も) |
| `vcpkg-commit`  | 任意   | (`vcpkg.json` から自動)    | SHA の override。`vcpkg.json` を使わない場合 (classic mode) に明示する |
| `manifest-path` | 任意   | `./vcpkg.json`             | `builtin-baseline` を読む `vcpkg.json` のパス |
| `feed-url`      | 任意   | 自動導出                   | NuGet feed URL。デフォルトは `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json` |
| `feed-name`     | 任意   | `github-packages`          | NuGet source の内部キー |
| `vcpkg-root`    | 任意   | 自動導出                   | vcpkg のパス。`$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg` の順で解決 |

## Outputs

| 名前            | 説明                                                  |
|-----------------|-------------------------------------------------------|
| `feed-url`      | 解決後の feed URL                                     |
| `vcpkg-root`    | 解決後の vcpkg root                                   |
| `vcpkg-commit`  | vcpkg checkout を pin した SHA                        |

## 認証と permissions

- **Publisher mode** (`readwrite`): job に
  `permissions: { contents: read, packages: write }` を付ける
- **Consumer mode** (`read`): `packages: read` で十分
- **同一 owner への publish**: `${{ secrets.GITHUB_TOKEN }}` でそのまま動く
- **cross-owner の publish / read**: PAT (`write:packages` または
  `read:packages`) が必要
- **fork からの PR**: `GITHUB_TOKEN` には `packages:write` が付与
  されないため publish は失敗、cache miss は source build に fallback
  ( `actions/cache` と同じ挙動)

## 対応ランナー

Windows runner (`windows-latest`、`windows-2022` など) のみ。GitHub-hosted
Windows runner には vcpkg が `C:\vcpkg` に pre-install 済み。Linux /
macOS は対象外: `nuget.exe` が Mono を要求し、また Windows 向け MSVC
ビルドの binary caching が設計の中心であるため。

## 読み取り専用 (consumer) モード

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
    # cache hit: download / cache miss: ローカル build (push はしない)
```

## より深く理解したい方へ

以下を知りたい場合:

- vcpkg とは何か (中央バイナリ registry が無く、ソースからビルドする仕組み)
- Classic mode と manifest mode
- なぜ vcpkg checkout の pin が必要か (「ABI hash」とは何か)
- `builtin-baseline` と `vcpkg-commit` の関係
- vcpkg リリース SHA の選び方
- VS integration が `vcpkg install` を自動実行する仕組み
- `x64-windows-static-md` triplet の落とし穴
- Multi-solution リポジトリのパターン
- よくある誤解 / FAQ

→ [`docs/vcpkg-guide.ja.md`](docs/vcpkg-guide.ja.md) ([English](docs/vcpkg-guide.md))

## なぜ `actions/cache` ではなくこの action か

ネット上の多くのチュートリアルは「`vcpkg/archives` を `actions/cache`
でキャッシュする」方式を紹介していますが、構造的に以下の問題が
あります:

| 観点                                  | `actions/cache`     | この action (NuGet)         |
|--------------------------------------|---------------------|------------------------------|
| キャッシュヒットの粒度                | tarball 全体         | port 単位                    |
| `builtin-baseline` 更新への耐性       | ❌ 全 miss           | ✅ 変わってない port は hit  |
| test 失敗時の保存 (post step)         | ❌ skip される       | ✅ port 単位で都度 push      |
| 退避ポリシー                          | 7 日 idle            | 永続                          |
| 同一 owner 配下の repo 間共有         | ❌                   | ✅                           |
| ローカル開発でも同じ cache に hit     | ❌                   | ✅                           |

依存グラフが大きいプロジェクトほど NuGet 方式の利益が大きく、また
ローカル開発にも自然に拡張できます。

## ライセンス

以下のいずれかから選択するデュアルライセンス:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

Apache-2.0 ライセンスで定義される範疇で本作品への inclusion を意図
して提出された contributions は、追加条件なしで上記デュアル
ライセンスとして扱われます。
