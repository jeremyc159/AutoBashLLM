#!/usr/bin/env bash

set -euo pipefail

############################################
# Config
############################################

MODEL="gpt-5"                              # Model gpt-5 ONLY (do not change)
TEMPERATURE="${TEMPERATURE:-1}"         # standard chat model supports temperature
MAX_TURNS="${MAX_TURNS:-50}"              # stop if the LLM goes in circles
TOKENS_PER_CMD_LIST="${TOKENS_PER_CMD_LIST:-12000}"  # trim command list for context

# Read API key from openai.key (required)
FILE_KEY="$(cat openai.key 2>/dev/null || true)"
OPENAI_API_KEY="${FILE_KEY}"

# Safety / UX
SAFE_MODE="${SAFE_MODE:-1}"               # 1 = ask confirmation per command, 0 = auto-execute
CMD_RUN_INDEX=1

# Pricing (per 1K tokens)
# You specified: Input $1.25 / 1M, Cached input $0.125 / 1M, Output $10.00 / 1M
COST_IN_PER_1K="${COST_IN_PER_1K:-0.00125}"
COST_IN_CACHED_PER_1K="${COST_IN_CACHED_PER_1K:-0.000125}"
COST_OUT_PER_1K="${COST_OUT_PER_1K:-0.01}"

LOGS_ROOT="logs"

############################################
# Helpers
############################################

die() { echo "✖ $*" >&2; exit 1; }

require_api_key() {
  [[ -n "${OPENAI_API_KEY}" ]] || die "API key required. Put it in ./openai.key"
}

nowstamp() { date '+%Y-%m-%d %H:%M:%S'; }

slugify() {
  # First 5 words -> lowercase -> keep [a-z0-9-]
  # shellcheck disable=SC2001
  echo "$1" \
    | awk '{ for(i=1;i<=NF && i<=5;i++) printf("%s%s",$i,(i<NF && i<5)?" ":""); }' \
    | tr '[:upper:]' '[:lower:]' \
    | tr ' ' '-' \
    | sed 's/[^a-z0-9-]//g; s/--\+/-/g; s/^-//; s/-$//'
}

confirm() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N] " ans || true
  [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]]
}

############################################
# System prompts (keep JSON structure)
############################################

SYSTEM_PROMPT_CORE="$(cat <<'EOF'
<<<SYSTEM-CORE>>>
You are a cautious Linux shell expert. Your sole task is to reach
the user's goal by proposing **safe, deterministic** shell commands that
exist in the provided command list. After each tool-run you will be shown
the command outputs and may propose more commands, or declare success.
EOF
)"

SYSTEM_PROMPT_FORMAT="$(cat <<'EOF'
<<<SYSTEM-FORMAT>>>
Always answer with **valid JSON** following this schema *exactly*:
`{
  "action": "run" | "complete" | "error",
  "commands": ["...","..."],   // required only when action=="run"
  "explanation": "short human-readable comment"
}`
No additional keys, no prose outside JSON.
Each string in the commands list will be a one line bash command that can be
executed independently of the others. Avoid destructive actions unless the user
explicitly asked for them and you have created a backup first.
EOF
)"

############################################
# Chat API (POST /v1/chat/completions)
# - Sends only expected fields: model, temperature, messages
# - On API error: print details and exit (no retry loop)
############################################
chat() {
  local _messages="$1"
  local _turn="$2"
  local req_file="$LOG_DIR/turn_${_turn}_request.json"
  local resp_file="$LOG_DIR/turn_${_turn}_response.json"

  # Write request body (kept minimal to avoid unknown-parameter errors)
  printf '{ "model": "%s", "temperature": %s, "messages": %s }\n' \
    "$MODEL" "$TEMPERATURE" "$_messages" > "$req_file"

  # Perform request and capture HTTP status
  local http_code
  http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' \
      https://api.openai.com/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${OPENAI_API_KEY}" \
      -d @"$req_file" || true)"

  # If transport failed, http_code will be empty
  if [[ -z "$http_code" ]]; then
    echo "✖ Network or curl error. See $resp_file (if any)."
    exit 1
  fi

  # API-level error? Exit immediately (no loop).
  if [[ "$http_code" -ge 400 ]]; then
    echo
    echo "✖ API error ($http_code):"
    if jq -e 'has("error")' "$resp_file" >/dev/null 2>&1; then
      jq -r '.error | "code: \(.code // "n/a")\nmessage: \(.message // "n/a")\nparam: \(.param // "n/a")"' "$resp_file" || cat "$resp_file"
    else
      cat "$resp_file"
    fi
    echo "• Response saved to: $resp_file"
    exit 1
  fi

  # Top-level error object (some servers still return 200 with error payloads)
  if jq -e 'has("error")' "$resp_file" >/dev/null 2>&1; then
    echo
    echo "✖ API error (payload):"
    jq -r '.error | "code: \(.code // "n/a")\nmessage: \(.message // "n/a")\nparam: \(.param // "n/a")"' "$resp_file" || cat "$resp_file"
    echo "• Response saved to: $resp_file"
    exit 1
  fi

  cat "$resp_file"
}

############################################
# Single session runner (returns: 0=complete, 2=llm-reported error, 1=other fail)
############################################
run_session() {
  local USER_PROMPT="$1"
  CMD_RUN_INDEX=1

  # Initialize logs
  local ts slug
  ts="$(date '+%Y-%m-%d_%H-%M-%S')"
  slug="$(slugify "$USER_PROMPT")"
  LOG_DIR="${LOGS_ROOT}/${ts}__${slug:-goal}"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/agent.log"

  echo "$(nowstamp) - User Prompt:" > "$LOG_FILE"
  echo "$USER_PROMPT" >> "$LOG_FILE"

  # Build static part of the conversation
  local CMD_LIST
  CMD_LIST="$(compgen -c | sort -u | head -n "${TOKENS_PER_CMD_LIST}" | paste -sd ' ' -)"
  local messages
  messages="$(jq -n --arg sys1 "$SYSTEM_PROMPT_CORE" \
                    --arg sys2 "$SYSTEM_PROMPT_FORMAT" \
                    --arg cmds "$CMD_LIST" \
                    --arg user "$USER_PROMPT" \
      '[{"role":"system","content":$sys1},
        {"role":"system","content":$sys2},
        {"role":"system","content":("Available commands: " + $cmds)},
        {"role":"user","content":$user}]')"

  local total_cost="0.000000"

  for (( turn=1; turn<=MAX_TURNS; turn++ )); do
    echo
    echo "=== Turn $turn ==="
    echo "• Working…"

    # Call API
    local resp_json
    resp_json="$(chat "$messages" "$turn")"

    # Token usage & estimated cost
    local prompt_tokens completion_tokens total_tokens cached_tokens noncached_tokens turn_cost
    prompt_tokens="$(echo "$resp_json" | jq -r '.usage.prompt_tokens // 0')"
    completion_tokens="$(echo "$resp_json" | jq -r '.usage.completion_tokens // 0')"
    total_tokens="$(echo "$resp_json" | jq -r '.usage.total_tokens // (0 + .usage.prompt_tokens + .usage.completion_tokens)')" || true
    cached_tokens="$(echo "$resp_json" | jq -r '.usage.prompt_tokens_details.cached_tokens // 0' 2>/dev/null || echo 0)"
    # guard against odd servers
    if [[ "$cached_tokens" -gt "$prompt_tokens" ]]; then cached_tokens=0; fi
    noncached_tokens=$(( prompt_tokens - cached_tokens ))

    # cost per 1K
    turn_cost="$(awk -v nin="$noncached_tokens" -v cin="$cached_tokens" -v out="$completion_tokens" \
                     -v pin="$COST_IN_PER_1K" -v pcc="$COST_IN_CACHED_PER_1K" -v pout="$COST_OUT_PER_1K" \
        'BEGIN { printf "%.6f", (nin*pin + cin*pcc + out*pout)/1000 }')"
    total_cost="$(awk -v a="$total_cost" -v b="$turn_cost" 'BEGIN{printf "%.6f", a+b}')"

    echo "• Tokens — prompt: $prompt_tokens (cached: $cached_tokens), completion: $completion_tokens, total: $total_tokens"
    echo "• Est. cost — this turn: \$$turn_cost  |  session total: \$$total_cost"

    echo "$(nowstamp) - LLM Response (turn $turn, \$${turn_cost})" >> "$LOG_FILE"

    # Extract content
    local content
    content="$(echo "$resp_json" | jq -r '.choices[0].message.content // empty')"
    if [[ -z "$content" ]]; then
      echo "✖ Empty content from API. See $LOG_DIR/turn_${turn}_response.json"
      echo "$(nowstamp) - Empty content (abort)" >> "$LOG_FILE"
      return 1
    fi

    # Validate JSON contract
    local action
    if ! action="$(echo "$content" | jq -er '.action')" 2>/dev/null; then
      echo "✖ LLM did not return valid JSON per contract. Aborting."
      echo "Raw content:"
      echo "$content"
      echo "$(nowstamp) - Invalid JSON (abort)" >> "$LOG_FILE"
      return 1
    fi

    # Append assistant JSON to history
    messages="$(echo "$messages" | jq --arg role "assistant" --arg cnt "$content" '. + [{"role":$role,"content":$cnt}]')"

    case "$action" in
      run)
        mapfile -t cmd_arr < <(echo "$content" | jq -r '.commands[]')
        tool_report=""
        for cmd in "${cmd_arr[@]}"; do
          echo
          echo "→ Command #$CMD_RUN_INDEX:"
          echo "  $cmd"

          if [[ "$SAFE_MODE" == "1" ]]; then
            if ! confirm "Run this command?"; then
              echo "  (skipped)"
              tool_report+=$'\n'"# CMD ${CMD_RUN_INDEX}: $cmd"$'\n'"# skipped by user"$'\n'
              ((CMD_RUN_INDEX++))
              continue
            fi
          fi

          # Execute command (capture out/err/exit)
          local out_file err_file exit_code
          out_file="$LOG_DIR/cmd_${CMD_RUN_INDEX}.out"
          err_file="$LOG_DIR/cmd_${CMD_RUN_INDEX}.err"

          set +e
          bash -lc "$cmd" >"$out_file" 2>"$err_file"
          exit_code=$?
          set -e

          echo "  exit=$exit_code"
          echo "  stdout: $(wc -c <"$out_file" 2>/dev/null || echo 0) bytes"
          echo "  stderr: $(wc -c <"$err_file" 2>/dev/null || echo 0) bytes"
          echo "  logs: $out_file | $err_file"

          # Compose tool report segment
          tool_report+=$'\n'"# CMD ${CMD_RUN_INDEX}: $cmd"$'\n'"# EXIT: $exit_code"$'\n'
          if [[ -s "$out_file" ]]; then
            tool_report+=$'--- STDOUT ---\n'"$(sed -e 's/\r$//' "$out_file" | tail -c 200000)"$'\n'
          else
            tool_report+=$'--- STDOUT ---\n<empty>\n'
          fi
          if [[ -s "$err_file" ]]; then
            tool_report+=$'--- STDERR ---\n'"$(sed -e 's/\r$//' "$err_file" | tail -c 200000)"$'\n'
          else
            tool_report+=$'--- STDERR ---\n<empty>\n'
          fi

          ((CMD_RUN_INDEX++))
        done

        # Feed outputs back to the model
        messages="$(echo "$messages" | jq --arg role "user" --arg cnt "$tool_report" '. + [{"role":$role,"content":$cnt}]')"
        ;;

      complete)
        echo
        echo "✓ Completed"
        echo "$(echo "$content" | jq -r '.explanation // "Done."')"
        echo "$(nowstamp) - Completed:" >> "$LOG_FILE"
        echo "$content" >> "$LOG_FILE"
        return 0
        ;;

      error)
        echo
        echo "⚠ LLM reported an error:"
        echo "$(echo "$content" | jq -r '.explanation // "Unknown error"')"
        echo "$(nowstamp) - LLM error:" >> "$LOG_FILE"
        echo "$content" >> "$LOG_FILE"
        return 2
        ;;

      *)
        echo "✖ Unknown action '$action'"
        echo "$(nowstamp) - Unknown action '$action'" >> "$LOG_FILE"
        return 1
        ;;
    esac
  done

  echo
  echo "✖ Reached MAX_TURNS ($MAX_TURNS) without success."
  echo "$(nowstamp) - Max turns reached." >> "$LOG_FILE"
  return 1
}

############################################
# Entry
############################################
require_api_key

initial_input="${*:-}"

while :; do
  if [[ -z "$initial_input" ]]; then
    echo
    read -r -p "Enter your goal (or press Enter to quit): " USER_PROMPT || true
    if [[ -z "${USER_PROMPT:-}" ]]; then
      echo "Bye."
      exit 0
    fi
  else
    USER_PROMPT="$initial_input"
    initial_input=""
  fi

  # Run one session
  if run_session "$USER_PROMPT"; then
    :
  else
    status="$?"
    # 0 complete, 2 llm error, 1 other fail (all continue to prompt again)
    if [[ "$status" -eq 1 ]]; then
      echo "Session ended with failure."
    elif [[ "$status" -eq 2 ]]; then
      echo "Session ended with LLM-reported error."
    fi
  fi

  # Prompt for another goal
  echo
  echo "— Session finished —"
  read -r -p "Enter another goal (or press Enter to quit): " initial_input || true
  if [[ -z "${initial_input:-}" ]]; then
    echo "Bye."
    exit 0
  fi
done
