# setup-vcpkg-nuget-cache (日本語)

[![CI](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml/badge.svg?branch=main)](https://github.com/jumboly/setup-vcpkg-nuget-cache/actions/workflows/self-test.yml)

[English README](README.md)

[vcpkg][vcpkg] の binary cache を、あなたのアカウントの
[GitHub Packages][github-packages] NuGet feed に配線する GitHub Action。
Windows + Visual Studio の CI ビルドが、毎回ソースから再コンパイルする
代わりにビルド済みバイナリを再利用できるようになります。

[vcpkg]: https://github.com/microsoft/vcpkg
[github-packages]: https://github.com/features/packages

## 想定読者

以下にあてはまる方を主な想定読者としています:

- **Windows + Visual Studio (MSVC)** で C++ プロジェクト (または C++
  依存を持つ Rust / .NET プロジェクト) を書いている
- 依存ライブラリを **vcpkg の manifest mode** で管理している
  (リポジトリ内の `vcpkg.json` で依存を宣言している)
- GitHub Actions の CI で毎回ソースから再ビルドが走り、15〜40 分
  かかっている

vcpkg を classic mode (`vcpkg install <port>` 直書き、manifest なし) で
使っている場合は [manifest mode への移行](#manifest-mode-への移行) を
参照してください。

## 何をする action か

vcpkg には [binary caching][vcpkg-binarycaching] という仕組みがあり、
一度ビルドした成果物を再利用できます。サポートされている backend の
1 つが NuGet feed で、GitHub Packages はあなたのアカウント単位で無料の
NuGet feed を提供しています。

ただし vcpkg と GitHub Packages を CI で接続する標準パターンは ~20 行の
YAML boilerplate (`vcpkg fetch nuget` → `nuget sources add` →
`setapikey` → `VCPKG_BINARY_SOURCES`) が必要です。**この action は
それを `uses:` 1 行に圧縮します**。あとは `vcpkg install` を manifest
mode で呼ぶだけで cache hit が効きます。

[vcpkg-binarycaching]: https://learn.microsoft.com/en-us/vcpkg/users/binarycaching

## クイックスタート

2 ステップ。まずリポジトリ root (または `vcpkg install` を呼びたい
ディレクトリ) に `vcpkg.json` を置きます:

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

`builtin-baseline` は `microsoft/vcpkg` の commit SHA で、依存解決される
全 port のバージョンを固定します。SHA の選び方は
[Baseline SHA の選び方](#baseline-sha-の選び方) を参照。

次に GitHub Actions の workflow に以下を追加:

```yaml
jobs:
  build:
    runs-on: windows-latest
    permissions:
      contents: read
      packages: write          # GitHub Packages へ publish するため必須
    steps:
      - uses: actions/checkout@v4

      - uses: jumboly/setup-vcpkg-nuget-cache@v2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          # 推奨: vcpkg.json の builtin-baseline と同じ SHA
          vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35

      - name: Install vcpkg dependencies
        run: vcpkg install --triplet=x64-windows-static-md
        # ./vcpkg.json を読む。cache hit: NuGet から download、
        # cache miss: ローカル build (publisher mode なら nupkg を push)。

      - name: Build
        run: cmake --preset windows-msvc && cmake --build out
```

Actions ログでの見え方:

- **初回 run (cold cache)**: `vcpkg install` が依存をソースから build
  (libspatialite + transitive deps で ~25 分)、終了時に各 port を
  GitHub Packages へ upload。
- **2 回目以降 (warm cache)**: vcpkg がビルド済み `.nupkg` を download。
  通常 1〜2 分程度で全 step 完了。

GitHub-hosted の `windows-latest` には vcpkg が `C:\vcpkg` に
pre-install 済みなので、bootstrap は不要です。

## 再現性: vcpkg を pin する

manifest mode の `builtin-baseline` は **port バージョン**を固定します。
このactionの `vcpkg-commit` 入力は **vcpkg ツール本体** (vcpkg.exe、
triplet ファイル、scripts) を固定します。両者を同じ SHA に揃えると、
CI が「あなたが選んだ ports tree に対してテストされた本来のツール
バージョン」で動くことが保証されます。

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v2
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
```

`vcpkg-commit` を指定すると、actionは `vcpkg-root` で
`git fetch && git checkout <sha>` を実行し、`vcpkg.exe` を再 bootstrap
します。タグ・ブランチ名でも動きますが、再現性のためには SHA 推奨です。

`vcpkg-commit` を省略すると runner image 同梱の vcpkg がそのまま使われ
ます。これは約 2 週間ごとに更新されるため、`builtin-baseline` とツールが
ズレてバージョン解決の warning / error が出ることがあります。**両方
セットすることを強く推奨**します。

### Baseline SHA の選び方

任意の `master` の SHA ではなく、`microsoft/vcpkg` のリリースタグの
commit を使うことを推奨します。リリースは全 port の整合性が取れた
スナップショットとしてテストされているためです。取得方法は 2 通り:

- **ブラウザから**:
  [microsoft/vcpkg/releases](https://github.com/microsoft/vcpkg/releases)
  を開き、使いたいリリース (基本は最新で OK) を選んで、タグの隣に表示
  される commit SHA をコピーする。
- **シェルから**:

  ```bash
  git ls-remote --tags https://github.com/microsoft/vcpkg.git \
    | grep -E 'refs/tags/[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' \
    | tail -5
  # 84bab45d415d22042bd0b9081aea57f362da3f35	refs/tags/2025.12.12
  # ...                                       (一番下が最新)
  ```

  左端の 40 文字 SHA をコピーする。

`vcpkg.json` の `builtin-baseline` と workflow の `vcpkg-commit` の
両方に同じ SHA を入れます。

### バージョンを上げたいとき

pin はオプトインの「停止」です。SHA を変えない限り古い vcpkg / ports を
使い続けます。新しい snapshot に更新するには:

1. 新しい SHA を選ぶ
2. **`vcpkg.json` の `builtin-baseline`** と **workflow の
   `vcpkg-commit:`** を **両方とも**新しい SHA に書き換えて commit
3. 次の CI run が新しい ports tree で cold build を行い、新しい nupkg を
   feed に publish する

数ヶ月おき、または「現在の pin より後に upstream に入った port バージョン
が必要」というタイミングで bump するのが目安です。

## Triplet について

vcpkg の *triplet* は「アーキテクチャ + OS + リンク方式 + CRT」を表す
識別子。VS の C++ プロジェクトでよく使うのは以下:

| Triplet                  | 意味 |
|--------------------------|------|
| `x64-windows`            | 64bit Windows、**DLL** (各ライブラリが個別の `.dll`) |
| `x64-windows-static`     | 64bit Windows、**static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64bit Windows、**static `.lib`** + **dynamic CRT** (`/MD`) — 単一実行ファイル配布する VS アプリで一般的 |

迷ったら `x64-windows-static-md` から始めるのが無難。ARM64 ビルドの場合は
`x64` を `arm64` に置き換えてください。triplet は自身の `vcpkg install
--triplet=...` 呼び出し側で指定します (action 側では vcpkg install を
実行しません)。

## 動作確認

初回 run 成功後:

1. `https://github.com/<your-account>?tab=packages` を開いて、`vcpkg.json`
   で宣言した port (とその transitive dependencies) が NuGet パッケージ
   として並んでいることを確認。
2. 同じ workflow を再 run。`vcpkg install` step が 1〜2 分で完了し、
   ログが `Building from source` ではなく NuGet feed からの restore
   メッセージに変わることを確認。

## よくあるエラー

| 症状 | 原因 / 対処 |
|------|-------------|
| `error: While loading manifest ...: ...` | `vcpkg.json` が壊れているか、`builtin-baseline` が無い。baseline SHA を追加。 |
| `error: ... could not find baseline ...` | `vcpkg.json` の `builtin-baseline` SHA をローカル vcpkg checkout が知らない。workflow の `vcpkg-commit:` に同じ SHA を指定する。 |
| push 時に `401 Unauthorized` | job に `packages: write` permission がない。Quick start の `permissions:` ブロックを追加。 |
| warm run のはずが全 port 再ビルドになる | (a) runner image の MSVC / Windows SDK が更新された、または (b) `builtin-baseline` / `vcpkg-commit` を bump した。(a) は不可避、(b) は意図的なはず — cache 安定性のためには SHA を据え置きする。 |
| fork からの PR で push 失敗 | 想定通り。fork PR の `GITHUB_TOKEN` には security 上 `packages: write` が付与されない。`if: github.event.pull_request.head.repo.full_name == github.repository` で publish step をガードするか、cold build を許容してください。 |

## Inputs

| 名前           | 必須   | デフォルト         | 説明 |
|----------------|--------|--------------------|------|
| `token`        | **必須** | —                | `packages:write` (または `mode: read` 時は `:read`) 権限を持つ GitHub token。same-account への publish なら `${{ secrets.GITHUB_TOKEN }}` で OK。 |
| `vcpkg-commit` | 任意   | `""`               | `microsoft/vcpkg` の commit SHA (タグ・ブランチも可) を指定して local checkout を pin する。**強く推奨**。`vcpkg.json` の `builtin-baseline` と同じ SHA を入れる。 |
| `feed-url`     | 任意   | 自動導出           | NuGet feed URL。デフォルトは `https://nuget.pkg.github.com/${{ github.repository_owner }}/index.json` (= 呼び出し repo の owner)。 |
| `feed-name`    | 任意   | `github-packages`  | NuGet source の内部キー。通常変更不要。 |
| `vcpkg-root`   | 任意   | 自動導出           | vcpkg のパス。`$VCPKG_INSTALLATION_ROOT` → `$VCPKG_ROOT` → `C:/vcpkg` の順に解決。 |
| `mode`         | 任意   | `readwrite`        | `read` (consumer 専用、publish しない) / `readwrite` (デフォルト、cache miss 時に publish)。 |

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
  - uses: jumboly/setup-vcpkg-nuget-cache@v2
    with:
      mode: read
      feed-url: https://nuget.pkg.github.com/<publisher-account>/index.json
      token: ${{ secrets.GITHUB_TOKEN }}
      vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
  - run: vcpkg install --triplet=x64-windows-static-md
    # cache hit: download / cache miss: ローカル build (push はしない)
```

`vcpkg.json` (`builtin-baseline` を `vcpkg-commit` と揃えたもの) は
consumer repo 側に通常通り置きます。

## manifest mode への移行

ビルドスクリプトや `actions/cache` で `vcpkg install <port>` を直接
呼んでいる場合、3 ステップで manifest mode に移行できます:

1. リポジトリ root に `vcpkg.json` を作り、現在 CLI で渡している port を
   `dependencies` に列挙する。`builtin-baseline` には `microsoft/vcpkg`
   の最新リリース SHA を入れる。
2. `vcpkg install <port> ...` の呼び出しを `vcpkg install` (引数なし、
   `vcpkg.json` を読む) に置き換える。
3. このactionに同じ SHA を `vcpkg-commit` として渡す。

これで同じ port をビルドしつつ、明示的なバージョン pin が効き、
ローカル/CI のパリティ (開発者の手元で `vcpkg install` を叩いても CI と
同じバージョンが入る) が手に入ります。

## なぜ `actions/cache` より良いか

ネット上の多くのチュートリアルは「`vcpkg/archives` を `actions/cache` で
キャッシュする」方式を紹介していますが、構造的に以下の問題があります:

| 観点                                  | `actions/cache`     | この action (NuGet)        |
|--------------------------------------|---------------------|----------------------------|
| キャッシュヒットの粒度                | tarball 全体         | port 単位                   |
| `builtin-baseline` 更新への耐性       | ❌ 全 miss           | ✅ 変わってない port は hit |
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
