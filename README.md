# にほちゃんマイク：場の話題

NIHO 鎌倉で交わされている話の要点を、連絡先や詳しい住所、センシティブな話題を避けて短く残すための実験的な Mac アプリです。会話に出た人名、広い出身地、職業は短文に含められます。既存の「録音から記事を作る」機能と並ぶ、にほちゃんマイクの二つ目の用途です。設計と段階的な公開範囲は [docs/design.md](docs/design.md) に記載しています。

## 現在の範囲（v1）

- 運営者が指定したマイクから録音し、macOS の SpeechTranscriber で Mac 内文字起こしする。
- Mac 内の AI で「その場の様子が伝わるか、後で役に立つか」を判定して話題を選び、日本語 140 文字以内の場の共有または伝聞の短文を Mac に保存する。
- 音声は 72 時間、生の文字起こしは 168 時間保持した後に削除する。
- NIHOappへの投稿、クラウド文字起こし、自動起動はまだ行わない。

録音と要約に使う Mac は **Apple Silicon・macOS 26 以上**が必要です。音声認識の日本語モデルと Mac 内 AI の利用可否は、その Mac で確認します。現地では、参加者への録音目的の説明を済ませたうえで開始し、必要なときはすぐ停止してください。

## MacBook での取得

```bash
git clone https://github.com/niho-life/niho-mic.git
cd niho-mic
swift build -c release
swift run niho-mic --help
```

## 現地 MacBook での最初の確認

Bluetooth マイクを macOS に接続し、**システム設定 → サウンド → 入力**で選べることを確認します。Terminal にマイクへのアクセスを許可し、**システム設定 → Apple Intelligence**を有効にしてモデルの準備完了を待ちます。

```bash
.build/release/niho-mic inputs
.build/release/niho-mic doctor
```

`doctor` が日本語音声モデルの未準備を示した場合は、次の明示操作で取得して再確認します。Mac 内 AI が未準備の場合は、モデルの準備を待って再実行してください。v1 は自動で外部 AI に切り替えません。

```bash
.build/release/niho-mic install-speech-model
.build/release/niho-mic doctor
```

運営者が現地で録音を始めるときは、`inputs` に表示されたマイクの **UID** を指定します。以下の `<マイクUID>` は実際の値に置き換えます。区切りは既定で120秒です。初回は認識精度と短文までの時間を確認してください。5分区切りで試す場合は、二つ目のコマンドを使います。

```bash
.build/release/niho-mic run --input '<マイクUID>'
.build/release/niho-mic run --input '<マイクUID>' --segment-seconds 300
```

**Ctrl-C** で停止します。既に同意を得て録音した短い音声があれば、`once --audio '<ファイルの絶対パス>'` でも処理できます。実音声、文字起こし、短文ログはこの公開リポジトリへ追加しないでください。

採用した短文は `~/Library/Application Support/life.niho.mic/logs/YYYY-MM-DD.jsonl` に記録されます。自分のMac上で見る場合の例:

```bash
jq -r 'select(.decision == "publish") | .text' "$HOME/Library/Application Support/life.niho.mic/logs/"*.jsonl
```

文字起こし・使用判定と理由・要約候補・最終短文・記録状態を順に確認するときは次を使います。区切りIDも表示されます。生の文字起こしが端末に出るので、画面共有中は注意してください。

```bash
.build/release/niho-mic inspect --latest 5
```

使用判定と要約の指示文は `Sources/NihoMicCore/LocalModels.swift` の `selectionInstructions` と `instructions` です。要約指示は「今こんな話をしている」という場の共有と、後で役立つ知識の両方に対応します。次の方法ならソースを変更・再ビルドせず、保存済み文字起こしに対して何度でも試せます。`preview` は採用ログを変更せず、重複判定を除く現在の出力検査まで実行します。

```bash
.build/release/niho-mic selection-prompt > "$HOME/Documents/niho-mic-selection-prompt.txt"
.build/release/niho-mic prompt > "$HOME/Documents/niho-mic-summary-prompt.txt"
open -e "$HOME/Documents/niho-mic-selection-prompt.txt"
open -e "$HOME/Documents/niho-mic-summary-prompt.txt"
.build/release/niho-mic preview --segment '<inspectに表示された64桁の区切りID>' --selection-prompt-file "$HOME/Documents/niho-mic-selection-prompt.txt" --prompt-file "$HOME/Documents/niho-mic-summary-prompt.txt"
```

`selection-prompt` は使用判定と話題選択、`prompt` は要約生成の指示です。最終の安全性確認の指示は同じ `LocalModels.swift` の `outputSafetyInstructions` にあります。候補の連絡先・詳しい住所・センシティブ内容・140字などの最終検査は `preview` でも有効です。編集するファイルには実際の会話や文字起こしを貼り付けず、公開リポジトリにも追加しないでください。

音声は72時間、文字起こしと要約候補の診断情報は168時間で削除します。稼働中と次回起動時に期限を確認します。停止中に期限が過ぎた場合は `.build/release/niho-mic prune` を実行できます。短文ログの削除は `.build/release/niho-mic delete-logs --confirm` です。

## 開発

```bash
swift test
```

公開CIには合成データを使い、Macのマイク、日本語音声モデル、個人のAIアカウントを要求しません。
