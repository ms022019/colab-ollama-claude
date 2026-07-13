# 使い方

Colab上のOllamaをClaude Codeのバックエンドとして使うための手順です。詳しい仕様・改善点は `README.md` を参照してください。

## 1. Colabノートブックを実行する

1. `colab_ollama_claude.ipynb` を Google Colab で開く
2. `ランタイム > ランタイムのタイプを変更 > T4 GPU` を選択
3. セルを**上から順に全部実行**する
   - 「5. モデルの pull」でモデル(約9〜10GB)のダウンロードに数分かかる
   - 「9. トンネルの起動」セルの出力に、**トンネルURL**・**APIキー**・ローカルで実行するコマンドが表示される

出力例:
```
Tunnel URL: https://xxxx-xx-xx.trycloudflare.com
API Key:    3f9a1c...

On your local machine, run:
  ./start-local-llm.sh https://xxxx-xx-xx.trycloudflare.com 3f9a1c...
```

## 2. ローカルからClaude Codeを起動する

このリポジトリのディレクトリで、Colabの出力に表示された**URLとAPIキーをそのまま引数に渡して**実行する。

```bash
cd /workspaces/grillMe_colab2
./start-local-llm.sh https://xxxx-xx-xx.trycloudflare.com <APIキー>
```

このスクリプトは以下を自動で行う:
1. `/health` への疎通確認(リトライ付き)
2. `/v1/messages` へのテスト送信(初回はモデルロードで遅いことがある)
3. 上記が成功したら `ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` 等を設定して `claude` を起動

引数なしで実行するとUsageが表示されるだけなので、必ずURLとAPIキーを渡すこと。
`claude` に渡す追加引数(例: `-p "質問"`)はそのまま末尾に付けられる:
```bash
./start-local-llm.sh https://xxxx-xx-xx.trycloudflare.com <APIキー> -p "1+1は?"
```

## 3. モデルを切り替えたいとき(例: qwen2.5-coder:14bへ)

APIキーを再生成しないよう、**Configurationセル(セル2)は再実行しない**。代わりにノートブックに新しいセルを追加して:

```python
MODEL_NAME = "qwen2.5-coder:14b"
print(MODEL_NAME)
```

を実行し、続けて「5. モデルの pull」セルを再実行する(新モデルのダウンロード)。
Ollama/FastAPI/トンネルの再起動は不要(次のリクエストから自動的に新モデルが使われる)。
トンネルURL・APIキーも変わらないので、`start-local-llm.sh` の再実行も不要。

## 4. tool_use(エージェント機能)が動くか確認する

1. **テキスト応答の確認**: `./start-local-llm.sh <url> <key> -p "1+1は?"`
2. **curlでtool_use確認**: README「curlでの動作確認」の「tools付き」の例を実行し、
   レスポンスに `"type": "tool_use"` と `"stop_reason": "tool_use"` が含まれるか確認
3. **実際にツールが動くか確認**: 対話モードで「簡単なPythonファイルを作って `hello.py` に保存して」と指示し、
   `Write` ツールが実行されてファイルが生成されるか確認(コードがテキスト表示されるだけなら失敗)

うまく動かない場合の切り分けはREADMEの「tool_use(エージェント機能)の検証手順」を参照。

## 注意事項(よくあるつまずき)

- **トンネルURLは毎回変わる**: ノートブックを再実行するたびに新しいURLになる。古いURLは使えない
- **Colabは約90分アイドルで切断される**: 切断されたらノートブックを再実行し、新しいURLで `start-local-llm.sh` をやり直す
- **初回リクエストは遅い**: モデルロードのため数十秒かかることがある(2回目以降は速い)
