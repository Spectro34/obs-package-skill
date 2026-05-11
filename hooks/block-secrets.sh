#!/usr/bin/env bash
# Hard guardrail: prevent secrets from leaking into the Claude context.
# Fires on PreToolUse for Bash and Read tools. Reads tool input JSON from stdin
# and rejects (exit 2) any operation that would expose credentials to the model.
#
# Why PreToolUse and not PostToolUse: Claude Code PostToolUse hooks cannot
# rewrite tool output — `additionalContext` only appends, and `decision: block`
# aborts the task. The only way to truly redact is to stop the read/command
# before it executes.
#
# Coverage:
#   - oscrc credentials       : ~/.oscrc, */oscrc, osc config --dump[-full]
#   - SSH private keys        : ~/.ssh/id_*, *.pem, *.key (excluding *.pub)
#   - GPG secret material     : gpg --export-secret-keys/subkeys, private-keys-v1.d
#   - Shell credential files  : ~/.netrc, ~/.authinfo
#   - Cloud credentials       : ~/.aws/credentials, ~/.config/gh/hosts.yml
#   - Inline HTTP auth        : curl/wget with Authorization header or -u user:pass
#   - Credential env vars     : env|printenv emitting *TOKEN*, *PASSWORD*, *API_KEY*

set -euo pipefail

HOOK_INPUT=$(cat)

# Parse the three fields we care about in one python invocation.
# Output as three separate lines so bash can read them positionally.
PARSED=$(echo "$HOOK_INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ti = data.get('tool_input', {}) or {}
    print(data.get('tool_name', ''))
    print((ti.get('command') or '').replace(chr(10), ' ').replace(chr(13), ' '))
    print(ti.get('file_path') or '')
except Exception:
    print('')
    print('')
    print('')
" 2>/dev/null)

TOOL_NAME=$(echo "$PARSED" | sed -n '1p')
COMMAND=$(echo "$PARSED" | sed -n '2p')
FILE_PATH=$(echo "$PARSED" | sed -n '3p')

reject() {
    echo "BLOCKED: $1" >&2
    echo "Reason: this would expose secrets to the model context." >&2
    echo "If you need to inspect this, do it in a regular terminal outside Claude Code." >&2
    exit 2
}

# Regex of secret-bearing path tails. Kept anchored to avoid matching files that
# happen to *contain* the substring (e.g., README.netrc.md).
SECRET_PATH_RE='(/\.oscrc$|/oscrc$|/\.netrc$|/\.authinfo$|/\.ssh/id_[a-z0-9_]+$|/\.gnupg/private-keys-v1\.d|/\.aws/credentials$|/\.config/gh/hosts\.yml$|\.pem$|\.key$|/id_rsa$|/id_ed25519$|/id_ecdsa$|/id_dsa$)'

# --- Read tool: check file_path ---
if [ "$TOOL_NAME" = "Read" ] && [ -n "$FILE_PATH" ]; then
    NORM_FP=$(echo "$FILE_PATH" | tr '[:upper:]' '[:lower:]')
    # Public keys are safe to read
    case "$NORM_FP" in
        *.pub) exit 0 ;;
    esac
    if echo "$NORM_FP" | grep -qE "$SECRET_PATH_RE"; then
        reject "Read of secret-bearing file: $FILE_PATH"
    fi
    exit 0
fi

# Everything below targets Bash.
[ "$TOOL_NAME" != "Bash" ] && exit 0
[ -z "$COMMAND" ] && exit 0

# Normalize: collapse whitespace, lowercase
NORMALIZED=$(echo "$COMMAND" | tr '\n' ' ' | sed 's/  */ /g' | tr '[:upper:]' '[:lower:]')

# --- 1. File readers pointed at secret-bearing paths ---
# Match common readers, then require a secret path token in the same command.
# We exclude lines that mention *.pub so `cat id_rsa.pub` stays allowed.
READER_RE='\b(cat|head|tail|less|more|bat|xxd|od|strings|hexdump|tac|nl|base64|cp|mv|tar|zip|file)\b'
# Bash secret-path regex matches the same tails as Read, but loosened to allow
# the path appearing mid-command (followed by space/quote/pipe/end-of-line).
BASH_SECRET_PATH_RE='(/\.oscrc([^a-z0-9]|$)|/oscrc([^a-z0-9]|$)|/\.netrc([^a-z0-9]|$)|/\.authinfo([^a-z0-9]|$)|/\.ssh/id_[a-z0-9_]+([^a-z0-9.]|$)|/\.gnupg/private-keys-v1\.d|/\.aws/credentials([^a-z0-9]|$)|/\.config/gh/hosts\.yml|\.pem([^a-z0-9]|$)|\.key([^a-z0-9]|$)|/id_rsa([^a-z0-9.]|$)|/id_ed25519([^a-z0-9.]|$)|/id_ecdsa([^a-z0-9.]|$)|/id_dsa([^a-z0-9.]|$))'
if echo "$NORMALIZED" | grep -qE "$READER_RE" \
   && echo "$NORMALIZED" | grep -qE "$BASH_SECRET_PATH_RE" \
   && ! echo "$NORMALIZED" | grep -qE '\.pub([^a-z0-9]|$)'; then
    reject "command reads a secret-bearing file (private key, oscrc, netrc, aws credentials, etc.)"
fi

# --- 2. GPG secret-key export ---
if echo "$NORMALIZED" | grep -qE '\bgpg\b.*--export-secret-(keys|subkeys)\b'; then
    reject "gpg --export-secret-keys/--export-secret-subkeys would print private key material"
fi

# --- 3. osc config dumps (prints oscrc, including pass=) ---
if echo "$NORMALIZED" | grep -qE '\bosc\s+config\s+(--dump|--dump-full)\b'; then
    reject "osc config --dump prints oscrc credentials"
fi

# --- 4. env / printenv exposing credential-shaped variables ---
# Block when an env-dumping command appears AND a credential keyword appears
# in the same command — covers both `printenv TOKEN` and `env | grep TOKEN`.
# Bare `env` stays allowed (no credential keyword). `set` excluded because
# `set -euo pipefail` is ubiquitous in scripts.
if echo "$NORMALIZED" | grep -qE '\b(env|printenv)\b' \
   && echo "$NORMALIZED" | grep -qE '\b(token|password|passwd|secret|api[_-]?key|aws_secret|aws_access_key_id|gh_token|github_token|anthropic_api_key|openai_api_key)\b'; then
    reject "env/printenv would emit credential-named environment variables"
fi

# --- 5. curl/wget with inline auth ---
# Triggers on: -H 'Authorization: ...' / --header 'Authorization: ...' / -u user:pass / --user user:pass
if echo "$NORMALIZED" | grep -qE '\b(curl|wget)\b' \
   && echo "$NORMALIZED" | grep -qE '(authorization:\s|(-u|--user)\s+[^ ]+:[^ ]+)'; then
    reject "curl/wget contains inline credentials (Authorization header or -u user:pass)"
fi

# --- 6. git config exposing stored credentials ---
if echo "$NORMALIZED" | grep -qE '\bgit\s+config\s+(--global\s+|--system\s+|--local\s+)?--get\s+[a-z.]*\.(password|token|access[_-]?token)\b'; then
    reject "git config --get on a credential field"
fi

# --- 7. ssh-keygen -y on a private key (prints public form, but reads the private blob) ---
# Allow; ssh-keygen -y reads the private key file from disk to derive its pubkey but only outputs the public form.
# Skipping — not a leak.

exit 0
