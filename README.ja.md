# setup-vcpkg-nuget-cache (日本語)

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[English README](README.md)

[vcpkg][vcpkg] の port を [GitHub Packages][github-packages] の NuGet feed
にキャッシュし、必要なら `vcpkg install` まで一気にやる composite GitHub
Action。vcpkg の [binary caching][vcpkg-binarycaching] の **publisher 側**
を再利用可能な action として切り出すことを狙いとしています。

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages
[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

> **状態: 1.0 未満、開発中。**
> action のスケルトン (inputs/outputs、README、ライセンス) は揃っていますが、
> `action.yml` の shell ロジックは TODO の placeholder です。実装計画と現状は
> [`.claude/HANDOFF.md`](.claude/HANDOFF.md) を参照。

## なぜ

CI ごとに vcpkg port を一からビルドすると遅い (`libspatialite` + 依存で
`windows-latest` 上 25 分前後)。vcpkg の binary caching は port のビルド済み
バイナリを NuGet パッケージとしてキャッシュすることで解決しますが、典型的な
書き方は `nuget.exe` の取得、ソース登録、env 設定、`vcpkg install` といった
boilerplate が必要です。この action はそれを `uses:` 1 行に圧縮します。

既存の「`actions/cache` で `vcpkg/archives` を保存する」方式との比較:

| 観点                                  | `actions/cache`     | この action (NuGet)        |
|--------------------------------------|---------------------|----------------------------|
| キャッシュヒットの粒度                | tarball 全体         | port 単位                   |
| `vcpkg HEAD` 更新への耐性             | ❌ 全 miss           | ✅ 変わってない port は hit |
| `cargo test` 失敗 / job 失敗時の保存  | ❌ post step が skip | ✅ port 単位で都度 push     |
| 退避ポリシー                          | 7 日 idle            | 永続                        |
| 同一 owner 配下の repo 間共有         | 不可                 | 可能                        |
| 初期セットアップコスト                | 低                   | 低 (この action 経由)       |

## クイックスタート (publisher: build & upload)

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
      # ports は local に install され、同時に
      # https://nuget.pkg.github.com/<your-account>/ にも upload される
      - run: |
          # cmake / msbuild / cargo などからインストール済みライブラリを利用
```

## クイックスタート (consumer: download のみ)

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
          # vcpkg は feed から pull、miss ならローカル build (push はしない)
```

## Inputs

| 名前         | 必須   | デフォルト         | 説明 |
|--------------|--------|--------------------|------|
| `ports`      | 任意   | `""`               | install する port のカンマ区切りリスト。空なら env セットアップのみ。 |
| `triplet`    | 任意   | `""`               | vcpkg triplet。`ports` が指定されたとき必須。 |
| `feed-url`   | 任意   | 自動導出           | NuGet feed URL。デフォルトは `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json`。 |
| `feed-name`  | 任意   | `github-packages`  | NuGet source 名 (内部キー)。 |
| `token`      | **必須** | —                | `packages:write` (または `mode: read` 時は `:read`) 権限を持つ GitHub token。 |
| `vcpkg-root` | 任意   | 自動導出           | vcpkg のパス。`$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:\vcpkg` / `/usr/local/share/vcpkg` の順に解決。 |
| `mode`       | 任意   | `readwrite`        | `read` (consumer 専用) / `readwrite` (publisher)。 |

## Outputs

| 名前         | 説明                    |
|--------------|-------------------------|
| `feed-url`   | 解決後の feed URL。     |
| `vcpkg-root` | 解決後の vcpkg root。   |

## 認証と permissions

- 呼び出し側 job に `permissions: { contents: read, packages: write }`
  (publisher) または `packages: read` (consumer) を付ける必要あり。
- 同じ owner 配下への publish なら `${{ secrets.GITHUB_TOKEN }}` で十分。
- cross-owner の publish や別アカウントの feed からの read には PAT
  (`write:packages` / `read:packages` scope) が必要。
- fork からの PR の `GITHUB_TOKEN` には `packages:write` が付かないため
  publish は失敗する。cache miss はソース build に fallback する (この挙動は
  `actions/cache` と同じ)。

## 対応ランナー

| Runner            | 状態                                                                          |
|-------------------|-------------------------------------------------------------------------------|
| `windows-latest`  | 主ターゲット。vcpkg は `C:\vcpkg` に pre-install 済み。                         |
| `ubuntu-latest`   | 計画中。呼び出し側で vcpkg を bootstrap、`nuget.exe` 実行に Mono が必要。       |
| `macos-latest`    | 計画中。同上。                                                                 |

## 類似 action との比較

- [`lukka/run-vcpkg`][run-vcpkg] — 成熟・広く使われている。binary cache backend
  は GitHub Actions Cache のみ。NuGet feed への publish は **不可**。
  単一リポジトリで揮発キャッシュを使う場合に最適。
- [`johnwason/vcpkg-action`][johnwason] — `run-vcpkg` と類似スコープ、こちらも
  `actions/cache` 方式。NuGet publish なし。
- [`LegalizeAdulthood/vcpkg-nuget-cache`][legalize] — 既存の feed を読む側を
  セットアップする consumer 専用 helper。**publish 機能なし**。read 側はこちら、
  write 側はこの action、と組み合わせる位置付け。

この action は publisher 側で「ビルドした port を長期保存される NuGet feed に
アップロードする」空白地帯を埋めることを目的にしています。

[run-vcpkg]: https://github.com/marketplace/actions/run-vcpkg
[johnwason]: https://github.com/johnwason/vcpkg-action
[legalize]: https://github.com/LegalizeAdulthood/vcpkg-nuget-cache

## ライセンス

以下のいずれかから選択するデュアルライセンス:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

Apache-2.0 ライセンスで定義される範疇でこの作品への inclusion を意図して
提出された contributions は、追加条件なしで上記デュアルライセンスとして
扱われます。
