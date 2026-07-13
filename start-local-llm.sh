#!/usr/bin/env bash
#
# Usage: ./start-local-llm.sh <tunnel-url> <api-key> [claude args...]
#
# Points Claude Code at a Colab-hosted Ollama backend (via Cloudflare Tunnel),
# verifies connectivity, then execs `claude`.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <tunnel-url> <api-key> [claude args...]" >&2
  echo "  tunnel-url : e.g. https://xxxx-xx-xx.trycloudflare.com (printed by the Colab notebook)" >&2
  echo "  api-key    : the key printed by the Colab notebook's config cell" >&2
  exit 1
fi

TUNNEL_URL="${1%/}"
API_KEY="$2"
shift 2

echo "==> Backend: ${TUNNEL_URL}"

echo "==> Checking /health ..."
HEALTH_OK=0
for i in $(seq 1 10); do
  if HEALTH_BODY=$(curl -fsS --max-time 10 "${TUNNEL_URL}/health" 2>/dev/null); then
    HEALTH_OK=1
    break
  fi
  echo "    (attempt $i/10 failed, retrying in 3s...)"
  sleep 3
done

if [ "$HEALTH_OK" -ne 1 ]; then
  echo "!! Could not reach ${TUNNEL_URL}/health" >&2
  echo "   - Colabのノートブックがまだ実行中か確認してください" >&2
  echo "   - トンネルURLは再起動のたびに変わります。最新のURLをノートブックの出力から取得してください" >&2
  exit 1
fi

echo "    OK: ${HEALTH_BODY}"

echo "==> Sending a test request to /v1/messages (first request may be slow - model loading)..."
TEST_RESPONSE=$(curl -fsS --max-time 180 \
  -X POST "${TUNNEL_URL}/v1/messages" \
  -H "content-type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{
        "model": "claude-sonnet-4-5",
        "max_tokens": 32,
        "messages": [{"role": "user", "content": "Reply with the single word: ok"}]
      }' 2>&1) || {
  echo "!! Test request to /v1/messages failed:" >&2
  echo "${TEST_RESPONSE}" >&2
  echo "   - APIキーが正しいか確認してください" >&2
  echo "   - Colab側のFastAPIサーバー/Ollamaが起動しているか確認してください" >&2
  exit 1
}

if ! echo "${TEST_RESPONSE}" | grep -q '"type"[[:space:]]*:[[:space:]]*"message"'; then
  echo "!! Unexpected response from /v1/messages:" >&2
  echo "${TEST_RESPONSE}" >&2
  exit 1
fi

echo "    OK: got a valid message response"
echo "==> Starting Claude Code against the local LLM backend..."

export ANTHROPIC_BASE_URL="${TUNNEL_URL}"
export ANTHROPIC_API_KEY="${API_KEY}"
export ANTHROPIC_MODEL="deepseek-coder-v2:16b"
export ANTHROPIC_SMALL_FAST_MODEL="deepseek-coder-v2:16b"
export API_TIMEOUT_MS="600000"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"

exec claude "$@"
