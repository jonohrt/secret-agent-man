#!/bin/bash
# Mock agent for E2E tests — simulates Claude Code hook behavior
# Reads commands from stdin, fires hooks to SAM

PORT="${SAM_PORT:-4000}"
SID="${SAM_SESSION_ID:-unknown}"
BASE="http://localhost:${PORT}/api/hooks"

# JSON helper — no jq dependency
json_payload() {
  local event="$1" tool="$2" desc="$3"
  printf '{"event":"%s","session_id":"%s","tool":"%s","description":"%s"}' \
    "$event" "$SID" "$tool" "$desc"
}

while IFS= read -r line; do
  CMD=$(echo "$line" | awk '{print $1}')
  ARG1=$(echo "$line" | awk '{print $2}')
  ARG2=$(echo "$line" | cut -d' ' -f3-)

  case "$CMD" in
    PRE_TOOL)
      curl -s -X POST "$BASE" \
        -H 'Content-Type: application/json' \
        -d "$(json_payload "pre_tool_call" "$ARG1" "$ARG2")" \
        > /dev/null 2>&1
      ;;
    POST_TOOL)
      curl -s -X POST "$BASE" \
        -H 'Content-Type: application/json' \
        -d "$(json_payload "post_tool_call" "$ARG1" "")" \
        > /dev/null 2>&1
      ;;
    PERMISSION)
      echo "? Allow $ARG1 $ARG2 [y/N]"
      ;;
    SLEEP)
      sleep "$ARG1"
      ;;
    EXIT)
      exit "${ARG1:-0}"
      ;;
    *)
      echo "$line"
      ;;
  esac
done
