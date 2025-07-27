#!/usr/bin/env bash
# llm-agent.sh - Iteratively reaches a user-supplied goal by chatting with an LLM
# Usage:  ./llm-agent.sh "create a Python venv, install pandas and print its version"

set -euo pipefail

############################################
# Config
############################################

MODEL="${OPENAI_MODEL:-o3-2025-04-16}"
TEMPERATURE=0.3
MAX_TURNS=20                                # Stop if the LLM goes in circles ??
TOKENS_PER_CMD_LIST=12000                   # Truncate large command lists
OPENAI_API_KEY="$(cat openai.key 2>/dev/null || echo '')"
SAFE_MODE=1 # If 1 Each command will require user confirmation before execution. If 0, commands will be executed automatically.

CMD_RUN_INDEX=1

# o3-2025-04-16 standard pricing (Apr-2025):
#   input  $2.00 / 1M tokens  ?  $0.002  per 1K
#   output $8.00 / 1M tokens  ?  $0.008  per 1K
COST_IN=${COST_IN:-0.002}
COST_OUT=${COST_OUT:-0.008}

# -gpt-4o-mini
#COST_IN=${COST_IN:-0.00015}
#COST_OUT=${COST_OUT:-0.00030}

LOG_DIR="logs/$(date '+%Y-%m-%d_%H:%M:%S')"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/llm-agent.log"

case "$MODEL" in
  o3-* ) TEMPERATURE_ENFORCED_DEFAULT=true ;;
  *    ) TEMPERATURE_ENFORCED_DEFAULT=false ;;
esac


if [[ -z ${OPENAI_API_KEY} ]]; then
  echo "? Please export OPENAI_API_KEY first."; exit 1
fi
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"<user goal prompt>\""; exit 1
fi
USER_PROMPT="$1"

# Log the initial user prompt
echo -e "$(date '+%Y-%m-%d %H:%M:%S') - User Prompt:\n$USER_PROMPT" >> "$LOG_FILE"

############################################
# Build the *static* part of the conversation
############################################
# 1?? Available commands (trimmed for context budget)
CMD_LIST="$(compgen -c | sort -u | head -n ${TOKENS_PER_CMD_LIST} | paste -sd ' ' -)"

# 2?? System prompts (see full text after the script)
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
Each string in the commands list will be a one line bash command that can be executed independantly of the others, and will be automatically executed on the system through bash invokation.
EOF
)"

# Combine everything into the first message set
messages=$(jq -n --arg sys1 "$SYSTEM_PROMPT_CORE" \
                 --arg sys2 "$SYSTEM_PROMPT_FORMAT" \
                 --arg cmds "$CMD_LIST" \
                 --arg user "$USER_PROMPT" \
  '[{"role":"system","content":$sys1},
    {"role":"system","content":$sys2},
    {"role":"system","content":("Available commands: " + $cmds)},
    {"role":"user","content":$user}]')

############################################
# Helper: call OpenAI Chat API
############################################
chat() {
  local _messages="$1"

  if $TEMPERATURE_ENFORCED_DEFAULT; then
    temp_line=""          # omit the field entirely
  else
    temp_line="\"temperature\": $TEMPERATURE,"
  fi

  curl -sS https://api.openai.com/v1/chat/completions \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer $OPENAI_API_KEY" \
     -d @- <<JSON
{
  "model": "$MODEL",
  $temp_line
  "messages": $_messages
}
JSON
}

############################################
# Main loop
############################################
for (( turn=1; turn<=MAX_TURNS; turn++ )); do
  echo -e "\n?? *** LLM turn $turn ***"
  resp_json="$(chat "$messages")"

  if [[ -z $resp_json ]]; then
    echo "? Empty response from the API (network failure?)"
    exit 1
  fi

  # Did the API return an explicit error object?
  if jq -e '.error' <<<"$resp_json" >/dev/null 2>&1; then
    echo "? OpenAI API error:"
    jq -r '.error | "  Code: \(.code // "unknown")\n  Message: \(.message)"' <<<"$resp_json"
    exit 1
  fi

  # Make sure we actually received a chat message
  if ! jq -e '.choices[0].message.content' <<<"$resp_json" >/dev/null 2>&1; then
    echo "? Unexpected API payload no assistant message found."
    echo "??  Full JSON for inspection:"
    echo "$resp_json" | jq   # pretty-print for readability
    exit 1
  fi

  prompt_tokens=$(jq -r '.usage.prompt_tokens // 0'  <<< "$resp_json")
  completion_tokens=$(jq -r '.usage.completion_tokens // 0' <<< "$resp_json")
  total_tokens=$(jq -r '.usage.total_tokens // 0'      <<< "$resp_json")

  turn_cost=$(awk -v pin="$prompt_tokens" -v pout="$completion_tokens" \
                 -v ci="$COST_IN"      -v co="$COST_OUT" \
    'BEGIN { printf "%.6f", (pin*ci + pout*co)/1000 }')

  echo -e "??  Tokens prompt: $prompt_tokens  · completion: $completion_tokens  · total: $total_tokens"
  echo -e "??  Estimated cost this turn: \$${turn_cost}"

  echo "$(date '+%Y-%m-%d %H:%M:%S') - LLM Answer (\$${turn_cost}):" >> "$LOG_FILE"

  content="$(echo "$resp_json" | jq -r '.choices[0].message.content')"
  echo -e "?? Raw LLM response:\n$content"

  # Ensure JSON validity & extract action
  if ! action="$(echo "$content" | jq -er '.action')" 2>/dev/null; then
     echo "? LLM returned invalid JSON. Aborting."
     exit 1
  fi

  # Append assistant response to conversation history
  messages="$(echo "$messages" | \
              jq --arg role "assistant" --arg cnt "$content" \
              '. + [{"role":$role,"content":$cnt}]')"

  case "$action" in
    run)
        mapfile -t cmd_arr < <(echo "$content" | jq -r '.commands[]')
        # Collect outputs for the next round
        tool_report=""
        for cmd in "${cmd_arr[@]}"; do
          echo -e "\n?? Running: $cmd"

          if [[ "$SAFE_MODE" -eq 1 ]]; then
            read -p "Press enter to RUN"
          fi
          echo -e "$CMD_RUN_INDEX\t$cmd" >> "$LOG_FILE"

          if out="$(bash -c "$cmd" 2>&1)"; then
             echo "? Success"; echo "$out"
          else
             echo "??  Command exited with status $?"; echo "$out"
          fi

          echo "$out" >> "$LOG_DIR/$CMD_RUN_INDEX.txt"
          CMD_RUN_INDEX=$((CMD_RUN_INDEX + 1))


          # Build JSON snippet for the tool message
          tool_report="$(jq -n --arg c "$cmd" --arg o "$out" \
                       '.command=$c | .output=$o')"$'\n'"$tool_report"
        done
        # Add tool output as a new message
        messages="$(echo "$messages" | \
                   jq --arg role "user" \
                      --arg cnt "$tool_report" \
                      '. + [{"role":$role,"content":$cnt}]')"
        ;;
    complete)
        echo -e "\n?? LLM signalled completion:\n$(echo "$content" | jq -r '.explanation')"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - LLM signalled completion:" >> "$LOG_FILE"
        echo "$content" >> "$LOG_FILE"
        exit 0
        ;;
    error)
        echo -e "\n? LLM reported an error:\n$(echo "$content" | jq -r '.explanation')"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - LLM signalled an error:" >> "$LOG_FILE"
        echo "$content" >> "$LOG_FILE"
        exit 1
        ;;
    *)
        echo "? Unknown action '$action'"; exit 1
        ;;
  esac
done

echo -e "\n? Reached max turns ($MAX_TURNS) without success."
echo "$(date '+%Y-%m-%d %H:%M:%S') - Reached max turns ($MAX_TURNS) without success." >> "$LOG_FILE"
exit 1
