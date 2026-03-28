#!/usr/bin/env bash
# Hard guardrail: block osc submit request commands.
# Fires on PreToolUse for Bash tool. Reads the tool input JSON from stdin
# and rejects any command that would create an OBS submit request.
#
# Blocked patterns:
#   osc sr, osc submitrequest, osc request create,
#   osc api (POST|PUT) .*/request

set -euo pipefail

HOOK_INPUT=$(cat)

# Extract the command string from the tool input
COMMAND=$(echo "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tool_input = data.get('tool_input', {})
    print(tool_input.get('command', ''))
except:
    print('')
" 2>/dev/null)

# Nothing to check
[ -z "$COMMAND" ] && exit 0

# Normalize: collapse whitespace, lowercase for matching
NORMALIZED=$(echo "$COMMAND" | tr '\n' ' ' | sed 's/  */ /g' | tr '[:upper:]' '[:lower:]')

# Block: osc sr / osc submitrequest
if echo "$NORMALIZED" | grep -qE '\bosc\s+(sr|submitrequest)\b'; then
    echo "BLOCKED: osc submit request commands are not allowed. Create SRs manually outside of Claude Code." >&2
    exit 2
fi

# Block: osc request create
if echo "$NORMALIZED" | grep -qE '\bosc\s+request\s+create\b'; then
    echo "BLOCKED: osc request create is not allowed. Create SRs manually outside of Claude Code." >&2
    exit 2
fi

# Block: direct OBS API POST/PUT to /request endpoint
if echo "$NORMALIZED" | grep -qE '\bosc\s+api\s+.*(-X\s*(POST|PUT)|--method\s*(POST|PUT)).*(/request|/source.*\?.*cmd=)'; then
    echo "BLOCKED: direct OBS API request creation is not allowed." >&2
    exit 2
fi

exit 0
