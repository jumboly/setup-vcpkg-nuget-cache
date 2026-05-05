# setup-vcpkg-nuget-cache (日本語)

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[English README](README.md)

[vcpkg][vcpkg] を使った Windows + Visual Studio の CI ビルドを高速化する
GitHub Action。ビルド済みの依存ライブラリを NuGet パッケージとして
あなたのアカウントの [GitHub Packages][github-packages] feed にキャッシュ
します。初回 CI run は通常通り cold build、それ以降の run は再コンパイル
ではなくビルド済みバイナリを download します。

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages

> **状態: 1.0 未満、開発中。**
> action 本体は実装済 + `windows-latest` で end-to-end 動作確認済。
> v1.0 タグと Marketplace 公開はこれから。

## 想定読者

以下にあてはまる方を主な想定読者としています:

- **Windows + Visual Studio (MSVC)** で C++ プロジェクト (または C++
  依存を持つ Rust / .NET プロジェクト) を書いている
- 依存ライブラリ (`boost` / `libcurl` / `proj` 等) を **vcpkg** で
  install している
- GitHub Actions の CI で毎回ソースから再ビルドが走り、15〜40 分
  かかっている

## 何をする action か

vcpkg には [binary caching][vcpkg-binarycaching] という仕組みがあり、
一度ビルドした成果物を再利用できます。サポートされている backend の
1 つが NuGet feed で、GitHub Packages はあなたのアカウント単位で無料の
NuGet feed を提供しています。

ただし vcpkg と GitHub Packages を CI で接続する標準パターンは ~30 行の
YAML boilerplate (`vcpkg fetch nuget` → `nuget sources add` →
`setapikey` → env 設定 → `vcpkg install`) が必要です。**この action は
それを `uses:` 1 行に圧縮します**。

[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

## クイックスタート

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # GitHub Packages へ publish するため必須
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v1
        with:
          ports: libspatialite,boost-system     # vcpkg port をカンマ区切りで列挙
          triplet: x64-windows-static-md        # ↓ Triplet セクション参照
          token: ${{ secrets.GITHUB_TOKEN }}

      # 依存ライブラリは
      # $VCPKG_INSTALLATION_ROOT/installed/x64-windows-static-md/
      # 配下に install されます。あとは cmake / msbuild / cargo に進んでください。
      - name: Build
        run: cmake --preset windows-msvc && cmake --build out
```

Actions ログでの見え方:

- **初回 run (cold cache)**: action が `vcpkg install` を呼び、依存を
  ソースから build (libspatialite + transitive deps で ~25 分)、終了時に
  各 port を GitHub Packages へ upload。
- **2 回目以降 (warm cache)**: vcpkg がビルド済み `.nupkg` を download。
  通常 1〜2 分程度で全 step 完了。

GitHub-hosted の `windows-latest` には vcpkg が `C:\vcpkg` に
pre-install 済みなので、bootstrap は不要です。

## 再現性: vcpkg のバージョン固定

このactionは、デフォルトでは runner image に同梱された vcpkg の checkout を
そのまま使います。`windows-latest` image は約 2 週間ごとに更新され、その都度
`C:\vcpkg` の git tree が新しい commit に動きます。vcpkg の port バージョンは
そのツリー内の `ports/<name>/vcpkg.json` に焼き込まれているため、image が
更新されると、install するport のバージョンも、その transitive 依存の
バージョンも、利用者の制御の外で動く可能性があります。一度依存のバージョンが
変われば abi-hash が変化し、既存 NuGet エントリと一致しなくなって cache miss
となります (hash は依存ツリーを上方向に伝播するため、依存グラフ全体で miss
することも珍しくありません)。

決定論的なビルドが欲しい場合は、`vcpkg-commit` 入力で vcpkg の commit SHA を
指定してください:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    ports: libspatialite
    triplet: x64-windows-static-md
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35   # microsoft/vcpkg 2025.12.12 リリースの commit
```

指定すると、actionは vcpkg root で `git fetch && git checkout <sha>` を実行し、
`vcpkg.exe` を再 bootstrap します。これで ports tree 全体 (= 全 port の
バージョン) がそのコミット時点で固定されます。runner image が更新されても
cache は引き続き hit します — MSVC か Windows SDK のアップグレードだけが
唯一の cache 無効化要因として残ります。タグやブランチ名も動作しますが、
再現性のためには SHA 指定が推奨です。

### SHA の選び方

任意の `master` の SHA ではなく、`microsoft/vcpkg` のリリースタグの commit を
使うことを推奨します。リリースは全 port の整合性が取れたスナップショットとして
テストされているためです。取得方法は 2 通り:

- **ブラウザから**:
  [microsoft/vcpkg/releases](https://github.com/microsoft/vcpkg/releases)
  を開き、使いたいリリース (基本は最新で OK) を選んで、タグの隣に表示される
  commit SHA をコピーする。
- **シェルから**:

  ```bash
  git ls-remote --tags https://github.com/microsoft/vcpkg.git \
    | grep -E 'refs/tags/[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' \
    | tail -5
  # 84bab45d415d22042bd0b9081aea57f362da3f35	refs/tags/2025.12.12
  # ...                                       (一番下が最新)
  ```

  左端の 40 文字 SHA をコピーする。

### バージョンを上げたいとき

pin はオプトインの「停止」です。SHA を変えない限り古い vcpkg を使い続けます。
新しい ports snapshot に更新するには:

1. 新しい SHA を選ぶ (上記参照)
2. workflow の `vcpkg-commit:` を書き換えて commit
3. 次の CI run が新しい ports tree で cold build を行い、新しい nupkg を feed に
   publish する

数ヶ月おき、または「現在の pin より後に upstream に入った port バージョンが
必要」というタイミングで bump するのが目安です。

### manifest mode との関係

`vcpkg-commit` は vcpkg の manifest mode (`vcpkg.json` の `builtin-baseline`)
と排他ではなく併用可能です。manifest mode を使うプロジェクトでは、
`vcpkg-commit` と `builtin-baseline` に同じ SHA を指定するのを推奨します。
ツール側と解決される port バージョンが合致して挙動が予測しやすくなります。

## Triplet について

vcpkg の *triplet* は「アーキテクチャ + OS + リンク方式 + CRT」を表す
識別子。VS の C++ プロジェクトでよく使うのは以下:

| Triplet                  | 意味 |
|--------------------------|------|
| `x64-windows`            | 64bit Windows、**DLL** (各ライブラリが個別の `.dll`) |
| `x64-windows-static`     | 64bit Windows、**static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64bit Windows、**static `.lib`** + **dynamic CRT** (`/MD`) — 単一実行ファイル配布する VS アプリで一般的 |

迷ったら `x64-windows-static-md` から始めるのが無難。ARM64 ビルドの場合は
`x64` を `arm64` に置き換えてください。

## 動作確認

初回 run 成功後:

1. `https://github.com/<your-account>?tab=packages` を開いて、指定した
   port (とその transitive dependencies) が NuGet パッケージとして
   並んでいることを確認。
2. 同じ workflow を再 run。`setup-vcpkg-nuget-cache` step とそれが
   trigger する `vcpkg install` が 1〜2 分で完了し、ログが
   `Building from source` ではなく NuGet feed からの restore メッセージに
   変わることを確認。

## よくあるエラー

| 症状 | 原因 / 対処 |
|------|-------------|
| `triplet input is required when ports is non-empty` | `ports:` を指定したが `triplet:` がない。triplet を追加。 |
| push 時に `401 Unauthorized` | job に `packages: write` permission がない。Quick start の `permissions:` ブロックを追加。 |
| warm run のはずが全 port 再ビルドになる | (a) runner image の MSVC / Windows SDK が更新された、または (b) image 同梱の vcpkg checkout が動いて port バージョンが変わった。(a) は不可避だが、(b) は `vcpkg-commit` で固定できる。[再現性セクション](#再現性-vcpkg-のバージョン固定) 参照。 |
| fork からの PR で push 失敗 | 想定通り。fork PR の `GITHUB_TOKEN` には security 上 `packages: write` が付与されない。`if: github.event.pull_request.head.repo.full_name == github.repository` で publish step をガードするか、cold build を許容してください。 |

## Inputs

| 名前         | 必須   | デフォルト         | 説明 |
|--------------|--------|--------------------|------|
| `ports`      | 任意   | `""`               | install する port のカンマ区切りリスト。空なら feed セットアップのみ (`vcpkg install` は呼ばない)。 |
| `triplet`    | 任意   | `""`               | vcpkg triplet (Triplet セクション参照)。`ports` 指定時は必須。 |
| `feed-url`   | 任意   | 自動導出           | NuGet feed URL。デフォルトは `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json` (= 呼び出し repo の owner)。 |
| `feed-name`  | 任意   | `github-packages`  | NuGet source の内部キー。通常変更不要。 |
| `token`      | **必須** | —                | `packages:write` (または `mode: read` 時は `:read`) 権限を持つ GitHub token。same-account への publish なら `${{ secrets.GITHUB_TOKEN }}` で OK。 |
| `vcpkg-root` | 任意   | 自動導出           | vcpkg のパス。`$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg` の順に解決。 |
| `vcpkg-commit` | 任意 | `""`               | `microsoft/vcpkg` の commit SHA (タグ・ブランチも可) を指定すると、その commit に local checkout を pin する。空ならrunner image 同梱の commit を使用。[再現性セクション](#再現性-vcpkg-のバージョン固定) 参照。 |
| `mode`       | 任意   | `readwrite`        | `read` (consumer 専用、publish しない) / `readwrite` (デフォルト、cache miss 時に publish)。 |

## Outputs

| 名前         | 説明                  |
|--------------|-----------------------|
| `feed-url`   | 解決後の feed URL。   |
| `vcpkg-root` | 解決後の vcpkg root。 |

## 認証と permissions

- 呼び出し側 job に `permissions: { contents: read, packages: write }`
  (publisher) または `packages: read` (consumer) を付ける。
- **同じ GitHub account / org** 配下への publish なら
  `${{ secrets.GITHUB_TOKEN }}` で十分。
- **cross-account** publish や別アカウントの feed からの read には PAT
  (`write:packages` / `read:packages` scope) が必要。
- **fork からの PR**: `GITHUB_TOKEN` に `packages:write` が付かないため
  publish は失敗し、cache miss は source build に fallback します
  (これは `actions/cache` と同じ挙動)。

## 対応ランナー

Windows runner (`windows-latest`、`windows-2022` など) のみ。GitHub-hosted
Windows runner には vcpkg が `C:\vcpkg` に pre-install 済み。Linux / macOS は
対象外: `nuget.exe` が Mono を要求するうえ、本 action は Windows 向け MSVC
ビルドの binary caching を設計の中心に据えているため。Windows 以外の runner
で実行するとエラーで停止します。

## 読み取り専用 (consumer) モード

repo A が publish した feed を、repo B から publish せず読み取りだけ
したい場合の設定例:

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
    # cache hit: download / cache miss: ローカル build (push はしない)
```

## なぜ `actions/cache` より良いか

ネット上の多くのチュートリアルは「`vcpkg/archives` を `actions/cache` で
キャッシュする」方式を紹介していますが、構造的に以下の問題があります:

| 観点                                  | `actions/cache`     | この action (NuGet)        |
|--------------------------------------|---------------------|----------------------------|
| キャッシュヒットの粒度                | tarball 全体         | port 単位                   |
| `vcpkg HEAD` 更新への耐性             | ❌ 全 miss           | ✅ 変わってない port は hit |
| test 失敗時の保存 (post step)         | ❌ skip される       | ✅ port 単位で都度 push     |
| 退避ポリシー                          | 7 日 idle            | 永続                        |
| 同一 owner 配下の repo 間共有         | ❌                   | ✅                          |

依存グラフが大きいプロジェクトほど NuGet 方式の利益が大きくなります。

## ライセンス

以下のいずれかから選択するデュアルライセンス:

- [MIT License](LICENSE-MIT)
- [Apache License, Version 2.0](LICENSE-APACHE)

Apache-2.0 ライセンスで定義される範疇で本作品への inclusion を意図して
提出された contributions は、追加条件なしで上記デュアルライセンスとして
扱われます。
