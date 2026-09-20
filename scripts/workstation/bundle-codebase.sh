#!/usr/bin/env bash
# scripts/workstation/bundle-codebase.sh
# Generates a single high-density markdown snapshot of tracked files
# to auto-sync with your Google Drive / Gemini Notebook pipeline.

set -euo pipefail
shopt -s globstar nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_FILE="${OUTPUT_FILE:-${REPO_ROOT}/docs/planning/active-codebase.md}"

prepare_output() {
    mkdir -p "$(dirname "$OUTPUT_FILE")"
}

write_header() {
    prepare_output
    printf '# 📂 Active Codebase State\n\n' > "$OUTPUT_FILE"
    printf 'Last compiled: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$OUTPUT_FILE"
    printf 'This file provides high-density context of tracked configurations for AI alignment.\n' >> "$OUTPUT_FILE"
}

section_title() {
    printf '\n---\n\n%s\n' "$1" >> "$OUTPUT_FILE"
}

append_file() {
    local path="$1"
    local lang="$2"

    section_title "### 📄 File: ${path}"
    {
      printf '```%s\n' "$lang" >> "$OUTPUT_FILE"
      cat "$REPO_ROOT/$path" >> "$OUTPUT_FILE"
      printf '```\n'
    }  >> "$OUTPUT_FILE"
}

append_files() {
    local title="$1"
    local lang="$2"
    shift 2

    local files=()
    local path
    for glob in "$@"; do
        for path in "$REPO_ROOT"/$glob; do
            [ -f "$path" ] || continue
            files+=("${path#"$REPO_ROOT"/}")
        done
    done

    local tracked=()
    declare -A seen=()
    for path in "${files[@]}"; do
        [ -n "${seen[$path]:-}" ] && continue
        if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            seen[$path]=1
            tracked+=("$path")
        fi
    done

    if [ "${#tracked[@]}" -eq 0 ]; then
        return
    fi

    mapfile -t sorted < <(printf '%s\n' "${tracked[@]}" | sort)
    section_title "$title"
    for path in "${sorted[@]}"; do
        append_file "$path" "$lang"
    done
}

main() {
    write_header

    append_files '## 🛠️ Core Automation Files' 'text' Makefile local-profile.env azure-profile.env
    append_files '## 🐚 Active Shell Scripts' 'bash' 'scripts/**/*.sh' 'scripts/**/*.py'
    append_files '## ☸️ Declarative Kubernetes Manifests' 'yaml' 'manifests/**/*.yaml' 'manifests/**/*.yml' 'manifests/**/*.txt'
    append_files '## ☸️ Declarative Infrastructure Files' 'yaml' 'infrastructure/**/*.yaml' 'infrastructure/**/*.yml' 'infrastructure/**/*.tf'
    append_files '## 📁 Core Configuration Files' 'yaml' 'core/**/*.service' 'core/**/*.yaml' 'core/**/*.yml' 'core/**/*.template'
    append_files '## 📁 Inventory Files' 'yaml' 'inventory/**/*.env' 'inventory/**/*.ini'
    append_files '## 🧪 Test Files' 'bats/python' 'tests/**/*.bats' 'tests/**/*.py' 'tests/**/*.bash'

    printf '\nCodebase successfully compiled to %s!\n' "$OUTPUT_FILE"
}

main
