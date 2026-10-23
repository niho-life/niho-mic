# にほちゃんマイク：場の話題

NIHO 鎌倉で交わされている話の要点を、連絡先や詳しい住所、センシティブな話題を避けて短く残すための実験的な Mac アプリです。会話に出た人名、広い出身地、職業は短文に含められます。既存の「録音から記事を作る」機能と並ぶ、にほちゃんマイクの二つ目の用途です。設計と段階的な公開範囲は [docs/design.md](docs/design.md) に記載しています。

## 現在の範囲（v1）

- 運営者が指定したマイクから3分ずつ連続録音する。Mac内で発話の量と分類確信度を判定し、雑音や談笑が中心で強い発話判定の少ない区切りは文字起こし前に見送る。
- 既定はローカルWhisperとmacOS SpeechTranscriberの文字起こしを照合する。一致した発言でWhisper側に文末がない場合は、文章を区切りやすいApple側を後段へ渡す。両者が大きく食い違う区切りは要約しない。Apple単独、Whisper単独、Geminiも明示選択できる。
- Mac 内の AI で、聞き取れた各区切りの内部要約（140字以内）を先に作る。その後「その場の様子が伝わるか、後で役に立つか」を判定し、採用した話題だけ日本語80〜140字を目標にした投稿案を作って Mac に保存する。十分な根拠があって短い案の方が明瞭な場合は60〜79字も採用候補にする。発信を見送った区切りの内部要約も、話題の継続に使える。
- 同じ録音セッションの直近の内部要約を次の区切りへ渡す。内部要約だけが失敗して短文は採用できた場合は、その短文を内部メモに使う。別の録音開始や単発ファイル処理には自動で引き継がない。前区間の地名を補うときは元の文字起こしの出典を確認し、今回別の場所が明示されたら切り替える。同じセッションで最後の発話から15分以上会話がなければ文脈を失効させる。前区間の名前だけで現在の話者は決めない。
- 話題には文字起こしから抜き出した根拠の発言を付け、要約がそこから言えるか別のMac内AIで確認する。主語や因果が根拠を超えたら一度書き直し、なお裏付けられなければ別の話題を一度試す。明瞭な一文がある場合は、原文と一字ずつ一致する引用を伝聞で紹介する候補も使う。引用候補も長さ・危険語・出力安全性を検査する。
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

投稿文の生成だけは、任意でMac内の Ollama に切り替えて比較できます。Apple Intelligence は内部要約・話題選択・根拠確認・安全審査で引き続き必要です。モデルは `qwen3.5:4b` と `qwen3.5:9b` だけを受け付け、接続先はこのMacの `127.0.0.1` に固定しています。モデルが未取得またはサーバーが停止していれば、録音を始める前にエラーを示します。9Bは数GBの空き容量とメモリを使うため、まず短い実音声の `review-audio` で速度を測ってください。6時間の連続運転は現地MacBookで未検証です。

```bash
brew install ollama
ollama pull qwen3.5:9b
ollama serve                         # 別のTerminalで起動
NIHO_MIC_BODY_MODEL=qwen3.5:9b .build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr apple
```

`NIHO_MIC_BODY_MODEL` を付けない場合は従来どおりAppleのMac内AIで投稿文も作ります。Ollamaを選んでも、音声・文字起こし・投稿文はクラウドへ送信しません。別のMacへ移る際は、そのMacでもモデルを取得してください。

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

6時間ほどの運用では既定の `verified` を第一候補として試します。Mac内で完結し、音声量に応じたAPI料金はかかりません。音声診断を通った区切りをWhisperで文字起こしし、Appleでもう一度読み、正規化した3文字列のJaccard一致度が0.30未満なら見送ります。短すぎる結果や、Whisperに反復・定型幻覚がある場合も見送ります。照合を通過し、Whisper文に句点がなくApple文に句点がある場合だけ、Apple文を話題抽出と投稿案に使います。実録音3区間では、明瞭な講演0.63、談笑0.11、聞き取りにくい登壇0.14でした。この閾値は初期値で、現地録音を人が聞いて調整します。Whisperの認識確信度は誤認識でも高いことがあり、区間内VADは明瞭な講演の冒頭を欠落させたため、採用条件には使っていません。

Apple単独は速い一方、実録音で語句の取り違えがありました。Whisper単独は照合を省く比較用です。Geminiは試した講演で読みやすい文字起こしでしたが、[利用枠と追加クレジット](https://www.antigravity.google/docs/plans)があり、上記の利用条件にも注意が必要です。Mac miniでの以前の実測は2分音源でApple約2秒・Whisper約13秒、3分音源のWhisper＋採用判断＋要約が約32秒でした。照合と根拠審査を加えた処理時間は現地MacBookでも確認します。

```bash
.build/release/niho-mic run --input '<マイクUID>'
.build/release/niho-mic run --input '<マイクUID>' --asr whisper
.build/release/niho-mic run --input '<マイクUID>' --asr apple
.build/release/niho-mic run --input '<マイクUID>' --segment-seconds 300 --asr whisper
```

**Ctrl-C** で停止します。既に同意を得て録音した短い音声があれば、`once --audio '<ファイルの絶対パス>'` でも処理できます。単発処理は毎回独立した会話です。連続する複数ファイルを同じ会話として試す場合だけ、各回に同じ `--session '<任意の英数字ID>'` を指定します。実音声、文字起こし、短文ログはこの公開リポジトリへ追加しないでください。

録音の様子を別ウィンドウで見るには、MacBook Air のターミナルで新しいウィンドウを開き、次を実行します。録音元のウィンドウはそのままにしてください。画面は2秒ごとに更新され、録音状態・次の区切りまでの時間・音声診断／文字起こし／要約の処理段階・直近3区間の文字起こし、内部要約、採用判断と理由、投稿案、最終結果を表示します。文字起こしはその区間の認識が終わった時点で表示され、判断と投稿案は区間処理の完了後に表示されます。既定の区切りは180秒です。

```bash
cd ~/Documents/app/NIHO/niho-mic
.build/release/niho-mic monitor
# 件数を変える場合
.build/release/niho-mic monitor --latest 5
```

`monitor` 側の **Ctrl-C は表示だけを終了**し、録音は続きます。録音を止めるときは録音元のウィンドウで Ctrl-C を押します。`monitor` は保存先を読み取るだけで、録音・削除・再処理はしません。表示には生の文字起こしが含まれるので、画面共有やスクリーンショットに注意してください。録音状態はローカルの専用保存先にある短い状態ファイルで確認し、プロセスが落ちて更新が止まった場合は「停止中」と表示します。

その時間の予定が分かる場合は、UTF-8のローカルテキストにイベント名、予定されたゲスト、公開済みの肩書を書き、`--event-context-file '<予定テキストの絶対パス>'` を追加できます。予定は話題や固有名詞を理解する手掛かりです。実際に誰がその区間を話したか、何を発言したかの証拠にはせず、本文の新しい事実は文字起こしで確認します。ファイルは公開リポジトリに置かず、`run`、`once`、`review-audio`、`review-text`、`preview` で明示指定します。v2 ではNIHO Desktopが該当時間の予定を取得して渡す設計です。

```bash
.build/release/niho-mic once --audio '<5分以内の音声>' --event-context-file '<予定テキストの絶対パス>'
```

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

同じ録音で文字起こしから投稿案まで比較するときは `review-audio` を使います。結果は端末だけに表示し、録音ログや処理済み判定は変更しません。文字起こし、内部要約と継続話題、採用判断と理由、投稿候補、最終チェックが順に出ます。生の文字起こしを画面に出すため、画面共有中は注意してください。

```bash
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr apple
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr whisper
.build/release/niho-mic review-audio --audio '<5分以内の音声>'
.build/release/niho-mic review-audio --audio '<5分以内の音声>' --asr gemini
```

文字起こしだけをローカルのテキストファイルに保存済みなら、音声認識をやり直さず要約を試せます。投稿候補は80〜140字を目指し、60〜79字でも根拠が明瞭な場合は採用候補にします。話者の名乗りが確認できるときは名前や肩書も使えます。

```bash
.build/release/niho-mic review-text --transcript-file '<ローカルの文字起こし.txt>'
```

`review-text` も保存ログを変更しません。実際の文字起こしを公開リポジトリには置かないでください。

採用した短文は `~/Library/Application Support/life.niho.mic/logs/YYYY-MM-DD.jsonl` に記録されます。自分のMac上で見る場合の例:

```bash
jq -r 'select(.decision == "publish") | .text' "$HOME/Library/Application Support/life.niho.mic/logs/"*.jsonl
```

文字起こし・内部要約・使用判定と理由・投稿候補・最終短文・記録状態を順に確認するときは次を使います。区切りIDも表示されます。生の文字起こしが端末に出るので、画面共有中は注意してください。

```bash
.build/release/niho-mic inspect --latest 5
```

内部要約・使用判定・投稿案の指示文は `Sources/NihoMicCore/LocalModels.swift` の `internalInstructions`、`selectionInstructions`、`instructions` です。次の方法ならソースを変更・再ビルドせず、保存済み文字起こしに対して何度でも試せます。`preview` は採用ログを変更せず、重複判定を除く現在の出力検査まで実行します。

```bash
.build/release/niho-mic internal-prompt > "$HOME/Documents/niho-mic-internal-prompt.txt"
.build/release/niho-mic selection-prompt > "$HOME/Documents/niho-mic-selection-prompt.txt"
.build/release/niho-mic prompt > "$HOME/Documents/niho-mic-summary-prompt.txt"
open -e "$HOME/Documents/niho-mic-internal-prompt.txt"
open -e "$HOME/Documents/niho-mic-selection-prompt.txt"
open -e "$HOME/Documents/niho-mic-summary-prompt.txt"
.build/release/niho-mic preview --segment '<inspectに表示された64桁の区切りID>' --internal-prompt-file "$HOME/Documents/niho-mic-internal-prompt.txt" --selection-prompt-file "$HOME/Documents/niho-mic-selection-prompt.txt" --prompt-file "$HOME/Documents/niho-mic-summary-prompt.txt"
.build/release/niho-mic review-text --transcript-file '<ローカルの文字起こし.txt>' --internal-prompt-file "$HOME/Documents/niho-mic-internal-prompt.txt" --selection-prompt-file "$HOME/Documents/niho-mic-selection-prompt.txt" --prompt-file "$HOME/Documents/niho-mic-summary-prompt.txt"
```

`internal-prompt` は公開前の内部要約、`selection-prompt` は使用判定と話題選択、`prompt` は投稿案生成の指示です。投稿案生成では、選択済みの話題について本文だけを1行で返すように指示してください。従来の「話題: ...」「本文: ...」の2行形式からも本文を取り出せますが、その話題名では選択結果を変更しません。最終の安全性確認の指示は同じ `LocalModels.swift` の `outputSafetyInstructions` にあります。候補の連絡先・詳しい住所・センシティブ内容・140字などの最終検査は `preview` でも有効です。編集するファイルには実際の会話や文字起こしを貼り付けず、公開リポジトリにも追加しないでください。

音声は72時間、文字起こしと要約候補の診断情報は168時間で削除します。稼働中と次回起動時に期限を確認します。停止中に期限が過ぎた場合は `.build/release/niho-mic prune` を実行できます。短文ログの削除は `.build/release/niho-mic delete-logs --confirm` です。

## 開発

```bash
swift test
```

公開CIには合成データを使い、Macのマイク、日本語音声モデル、個人のAIアカウントを要求しません。
