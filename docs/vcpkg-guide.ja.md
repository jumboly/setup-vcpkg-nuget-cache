# このアクションを使うための vcpkg ガイド

[English version is here](vcpkg-guide.md)

このガイドは「なぜこのアクションがこういう形なのか」、そして「自信を
もって使うために vcpkg について何を知っておくべきか」を解説します。
vcpkg のエキスパートである必要はありません。ただ、40 文字の SHA を
眺めて「これを何にどう使えばいいの?」と固まった経験がある方には
役立つはずです。

README より長いのは意図的です。README は「どのボタンを押すか」を
書いたもの、こちらは「ボタンの裏で何が起きているか」を書いたもの。
裏側を理解しておけば、いつか必ず遭遇する驚きにパニックせず対応
できます。

## 1. vcpkg とは何か

`apt`、`yum`、`Homebrew`、`npm`、`cargo`、あるいは `conan` から来た方の
パッケージマネージャの心象は、たぶんこうです:

> パッケージマネージャは中央 registry からビルド済みバイナリを
> ダウンロードしてマシンに置くもの。

**vcpkg はこのモデルでは動きません。** この 1 点が、なぜこの action
が必要かをほとんど説明します。

### 中央バイナリ registry が存在しない

vcpkg.org のような「全プラットフォーム / 全 compiler バージョン /
全ビルドオプションの組み合わせの `.lib` / `.dll` をホストするサーバ」
は存在しません。`microsoft/vcpkg` の GitHub リポジトリにあるのは
**ビルドレシピ** であってバイナリではない。あなたが要求した依存は
すべて、最初に要求されたときに **手元のマシンでソースから
コンパイル** されます。(2 回目以降も同じ — binary cache を設定
しない限りは。それを設定するのがこの action です。)

この設計は C++ ABI の都合によるもの: MSVC 19.40 + `/MD` でビルド
した `libfoo.lib` と MSVC 19.41 + `/MT` でビルドしたものは互換性が
なく、両方が同じ libfoo ソースから来ていてもバイナリレベルで
別物。「全 compiler × 全リンク方式 × 全 CRT × 全 feature flag」の
組み合わせ爆発に対して中央でバイナリをホストするのは現実的では
ない。だから vcpkg は別解を取った: **レシピを配って手元で組ませる**。

### vcpkg リポジトリの中身

`microsoft/vcpkg` を clone する (またはランナー pre-install の
`C:\vcpkg` を使う) と入っているもの:

```
vcpkg/
├── vcpkg.exe                # ツール本体 (bootstrap-vcpkg.bat でビルド)
├── bootstrap-vcpkg.bat
├── ports/                   # パッケージごとのディレクトリ
│   ├── libspatialite/
│   │   ├── portfile.cmake   # ビルドレシピ
│   │   ├── vcpkg.json       # port メタデータ (version、依存)
│   │   └── *.patch          # upstream ソースに当てるパッチ (あれば)
│   └── ...                  # 約 2500 個の port
├── triplets/                # ターゲット記述子 (x64-windows ほか)
├── scripts/                 # ビルドヘルパ、CMake integration
└── versions/                # port ごとの「version → git tree SHA」index
```

それだけ。バイナリ blob は無し、registry への問い合わせも無し。
**リポジトリ自体がパッケージデータベース**。

### `vcpkg install libfoo` が実際にやっていること

`vcpkg install libfoo` を実行すると:

1. `ports/libfoo/portfile.cmake` (レシピ) を読む
2. upstream のソースをダウンロード — 通常は
   `github.com/upstream/libfoo/archive/v1.2.3.tar.gz` のような tarball
   をローカル downloads cache に
3. ダウンロードしたソースの SHA-512 を `portfile.cmake` の期待値と
   照合
4. port ディレクトリにあるパッチを適用 (大半の port は無し。
   一部は MSVC 互換性のため upstream にまだマージされていない
   修正を当てる)
5. アクティブな triplet 用にビルド設定 (CMake / autotools / 独自、
   port による)
6. MSVC でコンパイル
7. `vcpkg/installed/<triplet>/` にインストール
8. transitive 依存を先に再帰的にこの手順で処理

`libspatialite` の場合、この transitive グラフは 9〜10 port 深さで、
CI ランナーで合計 15〜40 分のコンパイル時間。

これがキャッシュにこだわる理由です: 全依存はローカルビルドで、
ローカルビルドは遅い。

### パッケージを要求する 2 つのやり方

vcpkg には 2 つの利用スタイルがあります:

**Classic mode** — コマンドラインで指定:

```powershell
vcpkg install libfoo libbar --triplet=x64-windows-static-md
```

vcpkg は手元 checkout の HEAD にある portfile を使う。プロジェクトに
declarative なファイルは作らない。即席の実験向き。欠点: 依存
リストが build script (またはあなたのシェル履歴) に住むので、
マシン間 / 開発者間で食い違いが出る。

**Manifest mode** — `vcpkg.json` で宣言:

```json
{
  "name": "my-app",
  "dependencies": ["libfoo", "libbar"],
  "builtin-baseline": "84bab45d415d22042bd0b9081aea57f362da3f35"
}
```

そして `vcpkg install` (引数なし) を実行。vcpkg はカレント
ディレクトリの manifest を読み、`builtin-baseline` SHA に対して
バージョン解決し、プロジェクトローカルの `vcpkg_installed/` に
インストールする。

**Manifest mode が現代のデフォルト**で、この action が推奨する
スタイル。`builtin-baseline` フィールドが port ごとのバージョン
ピン留めをマシン横断で持続させる — これがローカル + CI のキャッシュ
対称性を成立させる半分です。(残りの半分は vcpkg checkout 自体の
pin で、それは action が担当する。)

Classic mode も依然として動きます — [11 章](#11-classic-mode-で使う)
を参照 — ただし「declarative な依存宣言」と「バージョン pin」の
利点を捨てることになります。

## 2. なぜキャッシュが必要か

`vcpkg install libspatialite` を初回実行すると、9〜10 個の transitive
依存（proj、geos、sqlite3、libcurl、libxml2 等）を全部ソースから
ビルドします。`windows-latest` で 15〜40 分。push のたび、PR のたび、
nightly job のたび。

個人プロジェクトなら「面倒だな」で済みます。チーム全体で 1 日 50
push を 6 リポジトリにわたって出していれば、1 回 5 分のコーヒー休憩
×n 回が積み上がる。CI の請求が増え、フィードバックループが遅くなり、
やがて「ちょっとした修正でわざわざ push したくない」と人が躊躇する
ようになる。

vcpkg にはちゃんと答えがあります。
[binary caching](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching)
という機能で、一度ビルドした成果物を保管しておき、次回同じ設定が
要求されたらビルドする代わりにダウンロードします。cache hit すると
25 分のビルドが 90 秒のダウンロードになる。

問題は: **どこに保管するか?**

### `x-gha` の終焉

しばらくの間、人気のあった答えは `x-gha` backend (`actions/cache` と
同じストレージを使う) でした。Microsoft は 2024 年末にこれを廃止
しました。Actions Cache は vcpkg のアクセスパターンに合っておらず、
連携が壊れ続けたためです。

残っている well-supported な backend は NuGet feed、Azure Blob Storage
ほか。GitHub にコードを置いているなら **GitHub Packages の NuGet
feed** が自然な選択肢: アカウント枠内で無料、アクセストークンは
リポジトリと共通、別途クラウドアカウントの管理も不要。

このアクションはその backend を配線します。

## 3. ABI hash とは

vcpkg のキャッシュ key は「port のバージョン番号」**ではありません**。
もしバージョン番号だけだったら半分のケースでキャッシュが間違うはず:
MSVC 19.40 でビルドした `libfoo 1.2.3` と MSVC 19.41 でビルドした
`libfoo 1.2.3` は ABI レベルで非互換だが、バージョン番号は同じ
だからです。

そこで vcpkg は port のビルドごとに **ABI hash** を計算します。
出来上がる `.lib` / `.dll` に影響しうるすべてを混ぜ込んだもの:

- compiler のバージョン (MSVC のビルド番号まで)
- port のバージョン (例: `libspatialite 5.1.0`)
- `portfile.cmake` の中身 (ビルド手順)
- triplet ファイルの中身 (`x64-windows-static-md.cmake` 等)
- vcpkg の build scripts (`scripts/buildsystems/...`) の中身
- 直接依存のすべての port の ABI hash (再帰)
- ビルドオプション、feature flag

これらのうち 1 byte でも変われば ABI hash は変わり、cache miss に
なります。逆に全部一致すれば、別ランナー、別 OS のビルド環境、
あなたのラップトップ vs CI、どこでも cache hit します。

これは **良いこと**: cache hit は「いま手元でビルドしようとしている
ものと完全に同じ入力からビルドされたバイナリ」を意味する。信頼性
の源です。

同時に **脆い**: 目に見えない小さな変化が cache hit 率を破壊しうる。
何が壊したか突き止めるには「何がこれらの入力を制御しているか」を
理解する必要がある。

## 4. なぜ pin が必要か

`windows-latest` runner image には vcpkg が `C:\vcpkg` に
pre-install されている。便利。ただし GitHub は約 **2 週間ごとに**
runner image を更新し、そのときに同梱の vcpkg checkout が新しい
commit に bump されます — 新しい portfile、新しい triplet、新しい
build script。

物語仕立てで:

> **月曜日**。開発者が機能を push。CI が走る。`libspatialite` が
> 25 分かけて cold build。成果物が ABI hash `aaaa...` で NuGet feed
> に upload される。
>
> **火曜日朝**。GitHub が新しい runner image を rollout。同梱の
> vcpkg は `2025.12.12` になる (前日まで `2025.10.01`)。triplet
> ファイル `x64-windows-static-md.cmake` がフォーマット変更
> されている — 意味は同じ、空白が違うだけ。それでも: byte 列が
> 違う → ABI hash が違う。
>
> **火曜日昼**。同じ開発者が README の typo を 1 行修正して push。
> CI が走る。vcpkg が ABI hash `bbbb...` を計算する。NuGet feed に
> あるのは `aaaa...`、`bbbb...` ではない。cache miss。25 分の cold
> build。再び。
>
> **水曜日**。cold build。**木曜日**。cold build。
>
> いま feed には `aaaa` と `bbbb` の 2 つの libspatialite nupkg が
> 居て、どちらも再利用されず、ストレージを食うだけ。開発者は
> 「キャッシュとか言うやつ、結局効かないじゃん」と判断して全部
> 撤去する。

解決策は **vcpkg の checkout を特定の commit SHA に pin すること**。
そうすれば ports tree、triplet、scripts、`vcpkg.exe` がすべての run
で同一になる — runner image の下で何が起きようとも。

## 5. `builtin-baseline` と `vcpkg-commit` の関係

vcpkg にはここで似たような 2 つの概念があります。名前は紛らわしい
けれど pin する対象が違い、その関係が肝です。

### `builtin-baseline` (`vcpkg.json` のフィールド)

```json
{
  "name": "my-app",
  "dependencies": ["libspatialite"],
  "builtin-baseline": "84bab45d415d22042bd0b9081aea57f362da3f35"
}
```

この SHA は **port のバージョン** を pin します。manifest mode で
依存解決するとき、vcpkg はこの SHA の時点の ports tree を git
plumbing で walk して、そこに登録されている `libspatialite` の
バージョンを引き、その時点の `portfile.cmake` を使ってビルドします。

つまり `builtin-baseline` が制御するのは「どの port バージョンを
得るか」と「どのビルド手順が使われるか」。

### `vcpkg-commit` (このアクションの入力)

これは **vcpkg checkout 全体** — `vcpkg.exe`、`triplets/*.cmake`、
`scripts/buildsystems/*` — を pin します。アクションが vcpkg-root
ディレクトリで以下を実行することで実現:

```
git fetch --tags origin
git checkout --detach <SHA>
bootstrap-vcpkg.bat -disableMetrics
```

working tree 全体がその SHA のスナップショットに書き換わり、
`vcpkg.exe` がその時点のソースから再ビルドされます。

つまり `vcpkg-commit` が制御するのは「ツール本体 + triplet + build
scripts」。

### なぜ両方必要か

ABI hash は `portfile + triplet + scripts + 依存` から計算される
ことを思い出してください。`builtin-baseline` が「port + portfile」
半分を、`vcpkg-commit` が「triplet + scripts + ツール」半分を担う。
**ABI hash を安定させるには両方 pin が必要**。

`builtin-baseline` だけ pin してツール側を放置するのが上の火曜日の
ストーリーです: port バージョンは固定だが新しい triplet → 新しい
ABI hash → cache miss。

### v1 のアクションがやっていること

ここがキモ: **v1 は `vcpkg.json` の `builtin-baseline` を読んで、
同じ SHA を `vcpkg-commit` として自動で使います**。書く SHA は 1 か
所 (`vcpkg.json`) だけ。両半分の pin が同時に効く。同期する 2 つ目
の SHA は存在しない。

```yaml
# これだけ。vcpkg-commit 入力は不要。
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
```

override したい場合 (例: そもそも `vcpkg.json` を置きたくない) は
`vcpkg-commit:` を明示すれば良い。これも動きます — [11 章](#11-classic-mode-で使う)
を参照。

## 6. SHA の選び方

vcpkg リポジトリは巨大で日々動いています。`master` の commit の
ほとんどは個別 port の更新で、典型的な port 更新は 1〜2 個の
`versions/*.json` を触るだけ。だからほぼどの SHA でも「動く」
のですが、問題は: **どの SHA が ports tree 全体として整合した
スナップショットか?**

**release tag の SHA を使うこと**。vcpkg は数ヶ月ごとに release
tag を切ります (`2025.12.12` のような年.月.日 形式)。各 release
tag は ports tree 全体に対する内部 CI を通したもの — その時点で
全 port が組み合わせとして動くことが確認されています。master HEAD
にこの保証はありません: ある瞬間に port A は機能 X が必要な版に
更新済み、port B はまだ X に対応していない、という不整合が一時
的に存在しうる。

release SHA を見つける方法 2 通り:

**ブラウザから:**
[microsoft/vcpkg releases](https://github.com/microsoft/vcpkg/releases)
を開く。最新を選ぶ。タグの隣に commit SHA が表示されている — 40
文字をコピー。

**シェルから:**

```bash
git ls-remote --tags https://github.com/microsoft/vcpkg.git \
  | grep -E 'refs/tags/[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' \
  | tail -5
# 84bab45d415d22042bd0b9081aea57f362da3f35	refs/tags/2025.12.12
# ...
```

左端が SHA。一番下が最新リリース。`vcpkg.json` の
`builtin-baseline` に貼り付ける。

### bump するタイミング

pin はオプトインの停止です。SHA を変えない限り同じ ports を
使い続ける。新しいスナップショットに進めるには:

1. 新しい release SHA を選ぶ (同じ手順)
2. `vcpkg.json` の `builtin-baseline` を更新。commit
3. 次の CI run が新しい ports tree で cold build を実行し、新しい
   nupkg を feed に publish する。以後は通常通り cache hit

数ヶ月おき、または「現在の pin より後に upstream に入った port
バージョンが必要」というタイミングで bump する目安。頻繁に bump
しないこと — bump 1 回ごとに cold build が 1 回入る。

## 7. Visual Studio integration

Visual Studio (またはコマンドラインの msbuild) で `.vcxproj` の
C++ プロジェクトをビルドする場合、**ビルドの一部として vcpkg が
依存を auto-install してくれる** ように設定できます。`vcpkg
install` を手で叩く必要なし。msbuild が適切な `vcpkg.json` を
見つけ、依存をビルド/取得し、結果のライブラリをプロジェクトに
リンクします。

これが動くには 3 つ条件:

1. **vcpkg integration が有効**。modern なやり方: VS や msbuild
   が起動するときに `VCPKG_ROOT` が環境にあること。VS 2022 と
   最近の msbuild は自動検出。(古いやり方: `vcpkg integrate
   install`、マシン全体の設定を書く)
2. **`vcpkg.json` が `.vcxproj` から到達可能**。msbuild は
   `.vcxproj` の場所から親方向にディレクトリを遡って `vcpkg.json`
   を探す。solution ディレクトリ (またはリポジトリ root) に置けば
   配下のすべてのプロジェクトが継承する
3. **`VCPKG_BINARY_SOURCES` が環境にある**。これが「NuGet feed を
   キャッシュとして使え」を vcpkg に伝える env。設定がないと
   auto-install は動くものの毎回ソースからビルドする

このアクションが `VCPKG_ROOT` も `VCPKG_BINARY_SOURCES` も
セットしてくれます。CI ではこうなる:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
- name: Build
  run: msbuild MyApp.sln /p:Configuration=Release /p:Platform=x64
  # msbuild が vcpkg install を自動実行。明示的な step 不要
```

ローカルではこう:

```powershell
$env:GH_TOKEN = "ghp_..."
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# 同じ shell で:
devenv .\MyApp.sln    # VS を開いて F7 でビルド。vcpkg auto-install
```

cache hit は **「タダで」** やってくる — 開発者の追加アクションは
shell session 1 回の PowerShell スクリプト実行のみ。

## 8. Triplet について

**triplet** はビルド対象 (アーキテクチャ + OS + リンク方式 + CRT)
を表す識別子。よく使うもの:

| Triplet                  | 意味 |
|--------------------------|------|
| `x64-windows`            | 64bit Windows、**DLL** (各ライブラリが個別の `.dll`) |
| `x64-windows-static`     | 64bit Windows、**static `.lib`** + **static CRT** (`/MT`) |
| `x64-windows-static-md`  | 64bit Windows、**static `.lib`** + **dynamic CRT** (`/MD`) — 単一 `.exe` 配布する VS アプリで一般的 |
| `arm64-windows`          | ARM64 Windows、DLL |
| `x86-windows`            | 32bit Windows、DLL |

### VS 自動 triplet の落とし穴

VS がビルド設定から vcpkg auto-install を起動するとき、triplet は
MSBuild の `Platform` プロパティから決まります:

| MSBuild Platform | デフォルト triplet  |
|------------------|---------------------|
| `x64`            | `x64-windows`       |
| `Win32`          | `x86-windows`       |
| `arm64`          | `arm64-windows`     |

注意: **デフォルトは DLL ビルド**。static lib + 動的 CRT
(`x64-windows-static-md`) を使いたいなら `.vcxproj` で明示する:

```xml
<PropertyGroup Label="Vcpkg">
  <VcpkgEnabled>true</VcpkgEnabled>
  <VcpkgTriplet Condition="'$(Platform)'=='x64'">x64-windows-static-md</VcpkgTriplet>
</PropertyGroup>
```

これがないと DLL ビルドになり、アプリ側が static lib を期待して
いるとリンクエラー (「unresolved external」) になる。よくある
ハマりどころ、知っていれば一瞬で直せます。

triplet で迷ったら: 単一 `.exe` 配布する VS アプリには
`x64-windows-static-md` が定番。

## 9. Multi-solution リポジトリ

実際のコードベースには 1 リポジトリに複数の solution が同居する
ケースがよくあります。きれいなパターンが 2 つあり、どちらも
アクションでサポート可能。

### パターン A: リポジトリ root に 1 つの `vcpkg.json`

```
repo/
├── vcpkg.json              ← 全 solution の依存 union + baseline
├── solutionA/solutionA.sln
└── solutionB/solutionB.sln
```

シンプル。リポジトリ配下のすべてのプロジェクトが親方向探索で
同じ `vcpkg.json` に到達する。`builtin-baseline` 管理は 1 か所。
solution 同士が大半の依存を共有しているならこれ。

### パターン B: solution ごとに `vcpkg.json`

```
repo/
├── solutionA/
│   ├── vcpkg.json          (A の依存、baseline: SHA-X)
│   └── solutionA.sln
└── solutionB/
    ├── vcpkg.json          (B の依存、baseline: SHA-X ← 同じ SHA!)
    └── solutionB.sln
```

各 solution が自分の依存を宣言する。solution が緩く関連している
だけで、各々が必要なものだけインストールしたい場合はこちら。

### なぜすべての `builtin-baseline` を揃えるべきか

vcpkg checkout (`C:\vcpkg`) は **単一の git working tree**、1 つの
SHA にしか pin できません。1 つの CI job 内で同時に 2 つの SHA に
することはできない。なので:

- 全 `vcpkg.json` が `builtin-baseline: SHA-X` なら、アクションは
  checkout を SHA-X に pin し、ABI hash が完璧に揃う
- `vcpkg.json` ごとに baseline が違う場合、vcpkg は動く (各
  baseline ごとに git tree traversal で portfile を取りに行く)
  けれど、アクションは 1 つの SHA にしか pin しない — つまり
  triplet/scripts のバイト列は solution 間で共通、portfile の
  バイト列は solution ごとに違う、という状態になる。cache は
  動くが、メンテナンス負担が増える (複数の SHA を歩調を揃えて
  bump する必要)

推奨: **リポジトリ全体で 1 つの SHA を選び、全 `vcpkg.json` に
書く**。バージョン bump 時は 1 PR で全部一度に更新。

### アクションの呼び出し

job 中 1 回で十分。アクションの効果 (pin + NuGet feed +
`VCPKG_BINARY_SOURCES`) は job 全体に効くので:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    manifest-path: solutionA/vcpkg.json    # SHA を持つ vcpkg.json なら何でも
- run: msbuild solutionA/solutionA.sln /p:Platform=x64
- run: msbuild solutionB/solutionB.sln /p:Platform=x64
```

`vcpkg.json` がリポジトリ root にあるなら `manifest-path` は省略
可能。

## 10. ローカルと CI で cache を共有する仕組み

複数マシン間で cache hit するには ABI hash が一致する必要がある。
hash は compiler / port version / portfile / triplet / scripts /
依存 hash から計算される。手元と CI でこれらを揃えるには:

- **compiler のバージョン**: CI と同じ MSVC バージョンをローカル
  にもインストール (または「leaf プロジェクトだけ再ビルドが入る
  かも」を許容。MSVC への依存性は port チェーンの末端ほど強い)
- **port version + portfile**: `vcpkg.json` の `builtin-baseline`
  が担う。同じ SHA → どこでも同じ portfile バイト列
- **triplet + scripts + vcpkg.exe**: vcpkg checkout の pin が担う。
  CI ではアクションが、ローカルでは同じ PowerShell スクリプトが
  実行する

これが「アクション本体とローカル PowerShell setup が **同一の
コード**」である理由。`tools/Setup-VcpkgCache.ps1` が CI で走り、
あなたのラップトップでも走る。drift しうる second implementation
は存在しない。

ローカルの動線:

```powershell
# shell session ごとに 1 回
$env:GH_TOKEN = "ghp_..."           # PAT (read:packages、必要なら write も)
.\tools\Setup-VcpkgCache.ps1 -Token $env:GH_TOKEN -Mode read

# 以降、同じ session 内で:
vcpkg install                       # CI と同じ triplet を build すれば cache hit
```

恒久化したい場合は PowerShell プロファイルに `VCPKG_BINARY_SOURCES`
だけ書いておき、`vcpkg.json` の SHA を変えたときだけ再度
スクリプトを叩いて (再 pin + 再 bootstrap)。

## 11. classic mode で使う

`vcpkg.json` を置きたくない場合 — 例えば既存のビルドスクリプトが
`vcpkg install libfoo libbar --triplet=x64-windows-static-md` を
直接叩いている — もアクションは動きます。SHA を明示的に渡す:

```yaml
- uses: jumboly/setup-vcpkg-nuget-cache@v1
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    vcpkg-commit: 84bab45d415d22042bd0b9081aea57f362da3f35
- run: vcpkg install libfoo libbar --triplet=x64-windows-static-md
```

ローカル:

```powershell
.\tools\Setup-VcpkgCache.ps1 `
    -Token $env:GH_TOKEN `
    -Mode read `
    -VcpkgCommit 84bab45d415d22042bd0b9081aea57f362da3f35
```

「依存リストと SHA を `vcpkg.json` 1 か所に集約することによる
ローカル/CI の対称性」というメリットは失われますが、キャッシュ
自体は問題なく動く。

複数の開発者と CI が同じビルドをする必要があるプロジェクト —
つまり多くのプロジェクト — では **manifest mode (`vcpkg.json`
あり) を推奨**。classic mode は既存セットアップ、ad-hoc
スクリプト、小規模実験のための優雅な fallback 経路です。

## 12. よくある誤解

**「`vcpkg.json` があれば再現性が保証される」**

ほぼ。`vcpkg.json` は port version を pin するけれど、それは
`builtin-baseline` フィールドがあるとき限定。フィールドが無いと
vcpkg は手元 checkout の HEAD のバージョンを使う — つまり最後に
`git pull` した日次第。baseline を入れること。

**「runner image にすでに vcpkg があるからキャッシュは
おまけ程度」**

runner image の vcpkg は 2 週間ごとに bump される。pin しないと、
bump のたびにキャッシュが事実上ワイプされる (triplet バイト列が
変わる → ABI hash が変わる)。runner refresh 直後の最初のビルドは
全部 cold build になる、`builtin-baseline` を変えていなくても。

**「`secrets.GITHUB_TOKEN` でローカル開発もできる」**

できない。`GITHUB_TOKEN` は CI 専用 secret で workflow run ごとに
生成される、ラップトップでは取得不可。ローカルで token を得る
現実的な方法は 2 つ:

1. **GitHub CLI の token を借りる**。すでに `gh auth login` 済みなら
   `gh auth token` で OAuth token が取れます。注意: デフォルトの
   `gh auth login` には `read:packages` / `write:packages` の scope が
   含まれません。1 度だけ追加:

   ```powershell
   gh auth refresh -s read:packages              # consumer
   gh auth refresh -s read:packages,write:packages   # publisher
   ```

   以降はどの shell でも:

   ```powershell
   .\tools\Setup-VcpkgCache.ps1 -Token (gh auth token) -Mode read
   ```

2. **Classic Personal Access Token (PAT) を生成**。
   [github.com/settings/tokens](https://github.com/settings/tokens)
   → Tokens (classic) → Generate new token。scope は
   `read:packages` (または `write:packages`)。token はパスワード
   同様に扱う — 環境変数 / credential manager / `.gitignore` した
   `.env.local` 等に保管、絶対 commit しない。

   注意: **fine-grained PAT は GitHub Packages に対して
   信頼性がない** — 特に organization の feed に対しては
   完全な対応が入っていません。classic PAT を使うこと。

**「`mode: read` でも誤って publish しちゃう?」**

しません。`read` mode は publish を無効化する — cache miss 時には
ローカルでビルドはするが、結果の `.nupkg` は upstream に push
されない。fork PR (どうせ `packages: write` をもらえない) や、
consume はしたいけど publish はしないリポジトリに正しい mode。

**「port のビルドが失敗したらキャッシュが壊れる?」**

壊れない。vcpkg はビルド成功後にしかキャッシュへ push しない。
失敗したビルドはキャッシュに何も残さない。

**「友人のプロジェクトが同じ NuGet feed に push したら、
そのビルドが見える?」**

そのプロジェクトのアカウント / org の feed を `feed-url` で指して、
そこへの read 権限がある場合のみ。デフォルトではアクションは呼び
出し元リポジトリの owner の feed
(`https://nuget.pkg.github.com/<owner>/index.json`) を使う。
クロスアカウント共有には対象 owner への `read:packages` 権限を
持つ PAT が必要。

---

このガイドの記述があなたの体験と食い違っていたり、ここでカバー
できていない罠を踏んだりしたら、[issue を立ててください](https://github.com/jumboly/setup-vcpkg-nuget-cache/issues) —
このガイドは現実のユーザーが踏んだ驚きとともに育つべきものです。
