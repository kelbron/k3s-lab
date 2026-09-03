#!/bin/sh
# Extracts variables referenced in a manifest that are also defined in a .env file.
# Standard: POSIX compliant stream processor (CWD/WSL/Debian compatible).
set -eu

ENV_FILE="${1:-}"
if [ -z "$ENV_FILE" ] || [ ! -f "$ENV_FILE" ] || [ ! -s "$ENV_FILE" ]; then
    # Return empty if env file is missing, invalid, or completely empty
    echo ""
    exit 0
fi

# AWK Stream processing:
# 1. Loads valid variable names from the .env file.
# 2. Scans the manifest stream (via stdin) for variable placeholder patterns.
# 3. Intersects and outputs formatted keys for envsubst (e.g., "$DOMAIN $VIP").
awk '
    FILENAME == ARGV[1] {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/^export[ \t]+/, "", line)
        if (line ~ /^[A-Za-z0-9_]+=/) {
            split(line, parts, "=")
            env_keys[parts[1]] = 1
        }
        next
    }
    {
        line = $0
        while (match(line, /\$[A-Za-z0-9_]+|\$\{[A-Za-z0-9_]+\}/)) {
            var = substr(line, RSTART, RLENGTH)
            gsub(/[\$\{\}]/, "", var)
            if (var in env_keys) {
                matched_keys[var] = 1
            }
            line = substr(line, RSTART + RLENGTH)
        }
    }
    END {
        for (k in matched_keys) {
            printf "$%s ", k
        }
        printf "\n"
    }
' "$ENV_FILE" -
