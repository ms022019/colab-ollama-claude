# Ollama + FastAPI + Cloudflare Tunnel → Claude Code バックエンド (Colab T4)

Google Colab の無料GPU(T4)上で Ollama を動かし、Anthropic Messages API 互換の `/v1/messages` を
FastAPI で提供、Cloudflare Tunnel で公開して、ローカルの Claude Code のバックエンドとして使えるようにするセットアップです。

元ネタ: [gist.github.com/SanjayPG](https://gist.github.com/SanjayPG/f6ae22a06f05be3628df24ab6a03341c)

## アーキテクチャ

```
[ローカル PC]                          [Google Colab (T4 GPU)]
  claude (Claude Code CLI)                  Ollama (deepseek-coder-v2:16b)
    │  ANTHROPIC_BASE_URL                        │  http://127.0.0.1:11434
    ▼                                             ▼
  https://xxxx.trycloudflare.com  ──────▶  FastAPI (/v1/messages, port 8000)
       (Cloudflare Tunnel)                        │
                                          cloudflared tunnel --url http://localhost:8000
```

## 元gistからの改善点

| # | 問題 | 対処 |
|---|------|------|
| 1 | `/v1/messages` が tool_use(ツール呼び出し)に未対応 | Anthropicの `tools`/`tool_use`/`tool_result` ⇔ OpenAIの `tools`/`tool_calls` を双方向変換(non-stream/stream両方)。モデルがtools非対応なら自動でtoolsを外してリトライ |
| 2 | `/v1/messages/count_tokens` が未実装 | 文字数ベースの簡易概算を実装(CJKは1文字≒1トークン、それ以外は4文字≒1トークン) |
| 3 | トンネルURLが無認証で公開される | `x-api-key` ヘッダー(または `Authorization: Bearer`)を検証。`/health` のみ認証不要 |
| 4 | 非ストリーミングの `timeout=60` が短い | `timeout=(10, 600)` (接続10秒/読み取り600秒)に延長 |
| 5 | (追加) `system` が配列形式のとき未対応 | Claude Codeが送る `system: [{"type":"text",...}]` に対応 |
| 6 | (追加) モデル名の不一致 | リクエストの `model`(例: `claude-sonnet-4-5`)を無視し、常にノートブック設定の `MODEL_NAME` へ転送 |
| 7 | (追加) エラーが200で返る | 適切なHTTPステータス + Anthropic形式のエラーボディに修正 |
| 8 | (追加) モデルがアンロードされ再ロードが遅い | `OLLAMA_KEEP_ALIVE=-1` で常駐化 |
| 9 | (追加) Qwen系モデルがtool_callsを構造化して返さず、`<tool_call>{...}</tool_call>` のようなプレーンテキストとしてツール呼び出しを出力するため、Claude Code側でJSONがそのまま表示されるだけでツールが実行されない | 応答テキストから `<tool_call>...</tool_call>`(または応答全体が1つのJSONのみのケース)を検出し、`tool_use` ブロックに変換。streamingではtools指定時のみ応答全体をバッファしてから同じ検出処理を適用 |

## セットアップ手順

1. `colab_ollama_claude.ipynb` を Google Colab で開く
2. `ランタイム > ランタイムのタイプを変更 > T4 GPU` を選択
3. 上から順に全セルを実行する
   - 「5. モデルの pull」で `deepseek-coder-v2:16b`(約10GB)のダウンロードに数分かかります
   - 「9. トンネルの起動」セルの出力に **トンネルURL** と **APIキー**、そしてローカルで実行すべきコマンドが表示されます
4. ローカルのこのディレクトリで、表示されたコマンドを実行:
   ```bash
   ./start-local-llm.sh https://xxxx-xx-xx.trycloudflare.com <APIキー>
   ```
   `/health` への疎通確認 → `/v1/messages` へのテスト送信 → 成功したら `claude` を起動します。

## 注意事項

- **トンネルURLは毎回変わります**: ノートブックを再実行(ランタイム再起動含む)するたびに新しいURLが発行されます。古いURLは使えません。
- **Colab無料枠は約90分のアイドルで切断されます**: ブラウザタブを閉じたり長時間操作しないと、Colabのランタイムが切断され、Ollama/FastAPI/トンネルがすべて止まります。加えて無料枠には数時間程度の連続利用上限もあります。切断されたら、ノートブックを再実行してください(トンネルURLは変わります)。
- **初回リクエストは遅い**: モデルロードのため、初回の応答に時間がかかります(数十秒程度)。`OLLAMA_KEEP_ALIVE=-1` によりロード後はメモリに常駐するため、2回目以降は速くなります。
- **VRAM使用量の目安**: T4は15GB。`deepseek-coder-v2:16b` は約10GB、`qwen2.5-coder:14b` も同程度で、どちらもT4に収まります。

## モデルの切り替え

ノートブックの「Configuration」セルの `MODEL_NAME` を書き換えるだけで切替できます。

```python
MODEL_NAME = "deepseek-coder-v2:16b"  # alt: "qwen2.5-coder:14b"
```

- `deepseek-coder-v2:16b`: 元gistのデフォルト。Ollamaのテンプレートが tools(関数呼び出し)に対応していない可能性があり、その場合 Claude Code のファイル編集・コマンド実行(エージェント機能)は動作せず、テキスト応答のみになります。
- `qwen2.5-coder:14b`: Ollamaで tool-calling 対応済み。T4のVRAMにも収まり、Claude Code のエージェント機能を実際に検証したい場合はこちらを推奨します。

## tool_use(エージェント機能)の検証手順

1. **テキスト応答の確認**(どのモデルでも動くはず)
   ```bash
   ./start-local-llm.sh <tunnel-url> <api-key> -p "1+1は何ですか?"
   ```
2. **(a) curlでtool_useブロックが返ることを確認**
   下記「curlでの動作確認」の「tools付き」の例を実行し、レスポンスの `content` 配列に
   `{"type": "tool_use", "id": "...", "name": "get_weather", "input": {...}}` が含まれることを確認します。
   - `id` が `toolu_` で始まる場合: モデルが構造化した `tool_calls` を返さず、プレーンテキスト
     (`<tool_call>...</tool_call>` 等)で応答したのをサーバー側のフォールバック検出が変換したものです。
   - `id` が `call_` で始まる場合: モデル(Ollama)自体が構造化 `tool_calls` を返しています。
   - いずれの形式でも `stop_reason` が `"tool_use"` になっていれば、Claude Code側でツールが実行されるはずです。
3. **(b) Claude Codeでエージェント機能を確認**
   対話モード(`./start-local-llm.sh <tunnel-url> <api-key>` を引数なしで実行)で、
   例えば「簡単なPythonファイルを作って `hello.py` に保存して」と指示し、
   実際に `Write` ツールが呼ばれてファイルが生成される(単にコードがテキスト表示されるだけで終わらない)ことを確認します。
4. **うまく動かない場合の切り分け**:
   - Colabノートブックのサーバーログ(FastAPIサーバーセルの出力)に
     `[warn] model ... rejected tools, retrying without tools` が出ていれば、そのモデルはOllama側でtools自体を受け付けていません(フォールバック検出の対象外)。
     → `MODEL_NAME` を `qwen2.5-coder:14b` に変更し、ノートブックの「5. モデルのpull」以降を再実行してください。
   - 上記の警告は出ていないのに `content` が `text` ブロックのみでJSONがそのまま表示される場合、
     モデルの出力が `<tool_call>...</tool_call>` 形式にも一致しない可能性があります。サーバーの
     `/v1/messages` レスポンス(またはstreamingの生ログ)を確認し、実際のテキスト形式に合わせて
     `extract_fallback_tool_calls`(サーバーセル内)の正規表現を調整してください。
5. **期待値についての注意**: 16B級のローカルモデルは、Claude本家のモデルに比べてエージェント能力(複数ステップの計画・複雑なツール呼び出し)が大幅に劣ります。簡単な単発のファイル操作程度は動く可能性がありますが、複雑なタスクは期待しないでください。

## curlでの動作確認

```bash
TUNNEL_URL="https://xxxx-xx-xx.trycloudflare.com"
API_KEY="<ノートブックで表示されたキー>"

# ヘルスチェック(認証不要)
curl "$TUNNEL_URL/health"

# 非ストリーミングのメッセージ
curl -X POST "$TUNNEL_URL/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
        "model": "claude-sonnet-4-5",
        "max_tokens": 200,
        "messages": [{"role": "user", "content": "Write hello world in Python"}]
      }'

# ストリーミング
curl -N -X POST "$TUNNEL_URL/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
        "model": "claude-sonnet-4-5",
        "max_tokens": 200,
        "stream": true,
        "messages": [{"role": "user", "content": "Count from 1 to 5"}]
      }'

# tools付き(tool_use検証)
# 期待される応答: content 配列に {"type": "tool_use", "name": "get_weather", "input": {"location": "Tokyo"}} 等が
# 含まれ、stop_reason が "tool_use" になっていること(text ブロックにJSONがそのまま出ていたら失敗)
curl -X POST "$TUNNEL_URL/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
        "model": "claude-sonnet-4-5",
        "max_tokens": 200,
        "tools": [{
          "name": "get_weather",
          "description": "Get the current weather for a location",
          "input_schema": {
            "type": "object",
            "properties": {"location": {"type": "string"}},
            "required": ["location"]
          }
        }],
        "messages": [{"role": "user", "content": "東京の天気を get_weather ツールで調べて"}]
      }'

# tools付き + streaming(バッファリング方式の確認 - 応答が届くまで少し待ってから
# message_start〜message_stop がまとめて流れてくるのが正常です)
curl -N -X POST "$TUNNEL_URL/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
        "model": "claude-sonnet-4-5",
        "max_tokens": 200,
        "stream": true,
        "tools": [{
          "name": "get_weather",
          "description": "Get the current weather for a location",
          "input_schema": {
            "type": "object",
            "properties": {"location": {"type": "string"}},
            "required": ["location"]
          }
        }],
        "messages": [{"role": "user", "content": "東京の天気を get_weather ツールで調べて"}]
      }'

# トークン数の概算
curl -X POST "$TUNNEL_URL/v1/messages/count_tokens" \
  -H "content-type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d '{
        "model": "claude-sonnet-4-5",
        "messages": [{"role": "user", "content": "Hello, how are you?"}]
      }'

# 認証なしでアクセス(401になることの確認)
curl -i -X POST "$TUNNEL_URL/v1/messages" \
  -H "content-type: application/json" \
  -d '{"model":"x","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```

## ファイル構成

- `colab_ollama_claude.ipynb` — Colab用ノートブック一式
- `start-local-llm.sh` — ローカル起動スクリプト
- `README.md` — このファイル
