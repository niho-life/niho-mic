# にほちゃんマイク：場の話題

NIHO 鎌倉で交わされている話の要点を、連絡先や詳しい住所、センシティブな話題を避けて短く残すための実験的な Mac アプリです。会話に出た人名、広い出身地、職業は短文に含められます。既存の「録音から記事を作る」機能と並ぶ、にほちゃんマイクの二つ目の用途です。設計と段階的な公開範囲は [docs/design.md](docs/design.md) に記載しています。

## 現在の範囲（v1）

- 運営者が指定したマイクから3分ずつ連続録音する。Mac内で発話の量と分類確信度を判定し、雑音や談笑が中心で強い発話判定の少ない区切りは文字起こし前に見送る。
- 既定はローカルWhisperで文字起こしし、macOS SpeechTranscriberの結果と照合する。両者が大きく食い違う区切りは要約しない。Apple単独、Whisper単独、Geminiも明示選択できる。
- Mac 内の AI で「その場の様子が伝わるか、後で役に立つか」を判定して話題を選び、日本語 140 文字以内の場の共有または伝聞の短文を Mac に保存する。
- 話題には文字起こしから抜き出した根拠の発言を付け、要約がそこから言えるか別のMac内AIで確認する。主語や因果が根拠を超えたら一度書き直し、なお裏付けられなければ別の話題を一度試す。
- 音声は 72 時間、生の文字起こしは 168 時間保持した後に削除する。
- NIHOappへの投稿と自動起動はまだ行わない。Gemini 指定時だけ音声を Google 側へ送る。要約と使用判定は引き続き Mac 内で行う。

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

既定の照合モード、またはWhisper単独を使う場合は、MacBook 側でも次を一度実行します。`whisper.cpp` は無料で、モデルは Mac 内に保存します。約 550 MB のダウンロードが必要です。取得後は `doctor` でAppleとWhisperの両方を確認できます。

```bash
brew install whisper-cpp
umask 077
model_dir="$HOME/Library/Application Support/life.niho.mic/models"
mkdir -p "$model_dir"
curl --fail --location --retry 3 \
  'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' \
  --output "$model_dir/ggml-large-v3-turbo-q5_0.bin.partial"
printf '%s  %s\n' \
  '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2' \
  "$model_dir/ggml-large-v3-turbo-q5_0.bin.partial" | shasum -a 256 -c - && \
  mv "$model_dir/ggml-large-v3-turbo-q5_0.bin.partial" "$model_dir/ggml-large-v3-turbo-q5_0.bin"
.build/release/niho-mic doctor
```

Gemini CLI 連携は比較実験として実装されています。ただし[Googleの公式FAQ](https://www.antigravity.google/docs/faq/)は、消費者向けプランで `agy` を外部アプリに組み込む方法をサポートしないと明記しています。**消費者向けAntigravityアカウントで、このアプリからの連続運用に使わないでください。**Googleの文字起こしが継続して必要なら、公式のGemini APIなどへ別途移行します。`--asr gemini` を選んだ場合は音声が Google 側へ送られ、CLI 側の会話履歴・保持はこのアプリの72時間／168時間削除の対象外です。自動フォールバックはありません。

利用条件に合う環境で比較する場合は、[Antigravity CLI の公式手順](https://www.antigravity.google/docs/cli/install/)で `agy` を準備・ログインし、`agy models` に `gemini-3.8-flash-low` があることを確認します。`doctor --asr gemini` は CLI の存在と Mac 内 AI を確認し、アカウント・モデルの利用可否は最初の文字起こしで確認します。

CLI には変換した音声の絶対パスを渡し、そのファイルを `read_file` で直接開かせます。音声だけを置いた専用作業ディレクトリで実行し、別ファイルの読取やコマンド実行を要求した結果は採用しません。ヘッドレス実行の権限を広げる設定や `--dangerously-skip-permissions` は不要です。作業音声は終了時に削除し、中断後も次回起動時に削除します。

```bash
agy models
.build/release/niho-mic doctor --asr gemini
```

運営者が現地で録音を始めるときは、`inputs` に表示されたマイクの **UID** を指定します。以下の `<マイクUID>` は実際の値に置き換えます。区切りは既定で180秒です。録音を止めずに直前の区切りを処理するため、処理中の会話も次の区切りに入ります。約1分以内の処理を目標に現地MacBookで計測し、処理待ちが2区切りに達した場合は録音を安全に停止します。

6時間ほどの運用では既定の `verified` を第一候補として試します。Mac内で完結し、音声量に応じたAPI料金はかかりません。音声診断を通った区切りをWhisperで文字起こしし、Appleでもう一度読み、正規化した3文字列のJaccard一致度が0.30未満なら見送ります。短すぎる結果や、Whisperに反復・定型幻覚がある場合も見送ります。実録音3区間では、明瞭な講演0.63、談笑0.11、聞き取りにくい登壇0.14でした。この閾値は初期値で、現地録音を人が聞いて調整します。Whisperの認識確信度は誤認識でも高いことがあり、区間内VADは明瞭な講演の冒頭を欠落させたため、採用条件には使っていません。

Apple単独は速い一方、実録音で語句の取り違えがありました。Whisper単独は照合を省く比較用です。Geminiは試した講演で読みやすい文字起こしでしたが、[利用枠と追加クレジット](https://www.antigravity.google/docs/plans)があり、上記の利用条件にも注意が必要です。Mac miniでの以前の実測は2分音源でApple約2秒・Whisper約13秒、3分音源のWhisper＋採用判断＋要約が約32秒でした。照合と根拠審査を加えた処理時間は現地MacBookでも確認します。

```bash
.build/release/niho-mic run --input '<マイクUID>'
.build/release/niho-mic run --input '<マイクUID>' --asr whisper
.build/release/niho-mic run --input '<マイクUID>' --asr apple
.build/release/niho-mic run --input '<マイクUID>' --segment-seconds 300 --asr whisper
```

**Ctrl-C** で停止します。既に同意を得て録音した短い音声があれば、`once --audio '<ファイルの絶対パス>'` でも処理できます。実音声、文字起こし、短文ログはこの公開リポジトリへ追加しないでください。

文字起こし前の音声判定だけを試すには次を使います。Mac標準のSound Analysisで発話らしさを判定し、発話候補が少ない場合や分類の確信度が低い場合に見送ります。音量だけでは雑音と発話を区別できないため、分類結果に秒数と割合のルールを適用します。発話判定は「言葉が正しく聞き取れる」保証ではありません。既定モードでは文字起こし後の照合、根拠の発言の抽出、Mac内AIによる要約の根拠確認も行います。

```bash
.build/release/niho-mic audio-check --audio '<5分以内の音声>'
```

同じ音声の文字起こしだけを比較するときは、次を使います。`transcribe` は音声判定を通さず、要約やログへの記録もせず、端末へ生の文字起こしを表示します。`once` と `run` は保存済み音声の重複処理を避けるため、同じファイルでエンジンを比較する用途には使えません。

```bash
.build/release/niho-mic transcribe --audio '<5分以内の音声>' --asr apple
.build/release/niho-mic transcribe --audio '<5分以内の音声>' --asr whisper
.build/release/niho-mic transcribe --audio '<5分以内の音声>' --asr verified
.build/release/niho-mic transcribe --audio '<5分以内の音声>' --asr gemini
```

同じ録音で文字起こしから投稿案まで比較するときは `review-audio` を使います。結果は端末だけに表示し、録音ログや処理済み判定は変更しません。文字起こし、採用判断と理由、要約候補、最終チェックが順に出ます。生の文字起こしを画面に出すため、画面共有中は注意してください。

```bash
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr apple
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr whisper
.build/release/niho-mic review-audio --audio '<5分以内の音声>'
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr gemini
```

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

`selection-prompt` は使用判定と話題選択、`prompt` は要約生成の指示です。要約生成は「話題: ...」と「本文: ...」の2行だけを受け付けます。以前に保存したプロンプトを使う場合もこの出力形式を指示してください。最終の安全性確認の指示は同じ `LocalModels.swift` の `outputSafetyInstructions` にあります。候補の連絡先・詳しい住所・センシティブ内容・140字などの最終検査は `preview` でも有効です。編集するファイルには実際の会話や文字起こしを貼り付けず、公開リポジトリにも追加しないでください。

音声は72時間、文字起こしと要約候補の診断情報は168時間で削除します。稼働中と次回起動時に期限を確認します。停止中に期限が過ぎた場合は `.build/release/niho-mic prune` を実行できます。短文ログの削除は `.build/release/niho-mic delete-logs --confirm` です。

## 開発

```bash
swift test
```

公開CIには合成データを使い、Macのマイク、日本語音声モデル、個人のAIアカウントを要求しません。
