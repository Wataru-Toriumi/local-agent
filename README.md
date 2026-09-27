# seiri

Swift製のローカルファイル整理CLI。Core AIでQwenを実行し、Downloadsの種類別整理と仕事の資料の内容別整理に使います。

## 動作

- `plan`: 直下のファイル名と本文の抜粋から整理案を作成。まだ移動しません。
- `apply`: 整理案を検証して分類先のサブフォルダに移動。移動前に履歴を保存します。
- `undo`: 履歴から元の場所に復元。中断したapply/undoからの復旧にも使えます。
- `doctor`: OSと、このバイナリにCore AIが組み込まれているかを表示。

Downloadsモード: `images / videos / audio / archives / installers / documents / code / other`

仕事モード: `invoices / contracts / meetings / reports / presentations / reference / other`

Downloadsモードでは既知の拡張子をSwiftのルールで分類し、それ以外をQwenに任せます。仕事モードではQwenが本文の抜粋から分類します。分類理由に「Qwen未使用」とある項目はルールでの判定です。

ファイル名を維持し、削除・上書きは行いません。同名の移動先がある場合は停止します。

## Core AI版のセットアップ

必要なもの: Apple Silicon Mac、macOS 27以上、Xcode 27以上、変換済みQwenモデル。

1. Xcode 27をインストールして初回起動を済ませます。以降のターミナルでは次のように選択できます（インストール先が違う場合は変更してください）。

   ```sh
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   xcrun --show-sdk-version
   ```

2. Appleの変換ツールを別ディレクトリに取得し、QwenをCore AI形式に変換します。`uv`が必要です。初回はモデルと依存ライブラリのダウンロードが発生します。以下はQwen3 1.7Bを変換する例です。分類品質は利用する資料の実例で評価してください。

   ```sh
   git clone https://github.com/apple/coreai-models.git /tmp/seiri-coreai-models
   cd /tmp/seiri-coreai-models
   git checkout e7b24da85ea64a77d26324d7ce9607de9b955f57
   uv run coreai.llm.export Qwen/Qwen3-1.7B --output-dir "$HOME/Models/seiri" --max-context-length 8192
   ```

   `--model`には、出力ログが示す**metadata.json、トークナイザー、.aimodelを含むリソースフォルダ**を指定します。`.aimodel`ファイル単体ではありません。Qwen3 1.7B/4B/8Bも公式の対応モデルに含まれます。

3. このリポジトリに戻りビルドします。

   ```sh
   unset SEIRI_WITHOUT_COREAI
   swift build -c release
   .build/release/seiri doctor
   ```

依存はApple公式の`CoreAILM`製品で、リビジョンを固定しています。Ollamaや外部推論サーバーは使いません。モデル取得後の分類処理に外部API呼び出しはありません。

## 依存関係とライセンス

このリポジトリには独自のSwiftソースと依存関係の定義だけを含め、Qwenの重み・変換済みモデル・外部ライブラリのソースやバイナリは含めません。Core AI Modelsは[BSD-3-Clause](https://github.com/apple/coreai-models/blob/main/LICENSE)、Qwen3 1.7Bは[Apache-2.0](https://huggingface.co/Qwen/Qwen3-1.7B/blob/main/LICENSE)です。Swift Package Managerが取得する推移的依存関係にはApache-2.0またはMITのものが含まれます。

変換済みモデルや依存ライブラリのバイナリを配布する場合は、それぞれのライセンスとNOTICEの同梱条件を確認してください。このプロジェクト自体のライセンスはまだ指定していません。

## 使い方

```sh
# Downloadsの整理案。MODEL_FOLDERは変換済みモデルの実際のパスに置き換える
.build/release/seiri plan ~/Downloads \
  --mode downloads --model /path/to/MODEL_FOLDER --out ./downloads-plan.json

# 仕事の資料の整理案
.build/release/seiri plan ~/Documents/Inbox \
  --mode work --model /path/to/MODEL_FOLDER --out ./work-plan.json

# 表示された移動先やJSONを確認後、適用
.build/release/seiri apply ./work-plan.json

# 取り消し
.build/release/seiri undo ./work-plan.json.journal.json
```

`plan`は移動一覧・理由・本文の抽出方式を表示し、JSONにも保存します。整理案と履歴は整理対象の**外**に保存してください。既存の整理案や履歴は上書きしません。再実行時は新しいファイル名を使います。エラー時の終了コードは1、成功は0です。

`apply --journal /path/to/history.json`で履歴の保存先を変えられます。取り消しが必要な間は履歴を保存してください。適用中は対象フォルダの`.seiri.lock`で、同じCLIによる同時操作を防ぎます。この隠しファイルと、取り消し後の空の分類フォルダは残ります。

## 読み取り範囲と制限

- 再帰走査はせず、直下の通常ファイルのみ対象。隠しファイル、シンボリックリンク、フォルダ、`.download/.crdownload/.part/.tmp`は除外。
- テキスト類は先頭16 KiBから最大4,000文字。PDFは20 MB以下の先頭3ページから最大4,000文字。
- スキャンPDF、ロックされたPDF、大きなPDF、Office文書、画像などはファイル名だけで判断します。OCR・Office本文抽出は未実装です。抽出方式は整理案の`extraction`で確認できます。
- モデルの出力はFoundation Modelsの`@Generable`と`@Guide`で構造化し、固定カテゴリに制限して検証。自由なパスやシェルコマンドを実行させません。不正な応答ならplanを失敗させます。分類品質は小規模なサンプルでの確認に限られ、任意の資料に対する精度を保証するものではありません。
- SHA-256で計画後・適用後の内容変更を検査。変更されたファイルは勝手に移動・復元しません。ハッシュ計算のため大きなファイルは読み取りに時間がかかります。
- 移動は同一ボリューム内のみ。分類フォルダを別ボリュームにマウントしている場合などは失敗し、履歴から復旧できます。
- 別アプリによる同時編集・フォルダの差し替えや、電源断に対する完全なトランザクション保証はありません。作業中のフォルダを避けて使ってください。
- 定期実行・フォルダ監視・自然言語の対話ループはまだありません。まずは明示的なplan/apply/undoを備える最小版です。

## SDKなしでファイル操作をテストする

```sh
./scripts/test.sh
.build/offline/debug/seiri --help
.build/offline/debug/seiri doctor

# 拡張子だけによる動作確認（Qwenは使わない）
.build/offline/debug/seiri plan /path/to/test-folder \
  --mode downloads --rules-only --out /tmp/seiri-test-plan.json
```

`SEIRI_WITHOUT_COREAI=1`は開発用の明示的なビルド切替です。Core AIが使えない場合に黙ってルール分類へ切り替えることはありません。このビルドで`--model`を使うとエラーになります。

テストでは一時フォルダだけを操作し、往復移動、衝突、内容変更、シンボリックリンク、パス逸脱、中断復旧、分類出力の検証を行います。

## 公式資料

- [Core AI](https://developer.apple.com/core-ai/)
- [Core AI Modelsと必要環境](https://github.com/apple/coreai-models)
- [Qwen3の対応モデル・変換・Swift API](https://github.com/apple/coreai-models/tree/main/models/qwen3)

## 実モデルでの動作確認

変換済みモデルを使い、架空の請求書・議事録・契約書をQwenで分類します。Downloadsでは拡張子のルール分類を確認します。両モードでapply/undoと内容のSHA-256一致を検査します。実際のDownloadsや仕事の資料は操作しません。

```sh
python3 scripts/model-smoke.py .build/release/seiri /path/to/MODEL_FOLDER
```

Core AIは初回実行時に`~/Library/Caches/coreai-cache`へモデルキャッシュを作成します。CLIを外部の厳しいサンドボックス内で起動するとキャッシュやGPUへのアクセスが拒否されるため、通常のターミナルから実行してください。
