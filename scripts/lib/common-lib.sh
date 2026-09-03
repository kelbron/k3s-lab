#!/usr/bin/env bash
# ==============================================================================
# Shared Helper Functions for Scripts
#
# Complies with:
# - ADR 011: Automation & Scripting Standards (Reusability & DRY)
# ==============================================================================

# Generic smart polling function
# Usage: wait_for_condition <retries> <wait_interval_seconds> <"Status Message"> <command...>
wait_for_condition() {
    local retries=$1
    local wait_time=$2
    local message=$3
    shift 3 # Remove the first 3 arguments so only the command remains in "$@"
    local cmd=("$@")

    echo "Waiting: ${message}..."
    for ((i=1; i<=retries; i++)); do
        # Execute the command silently
        if "${cmd[@]}" >/dev/null; then
            echo "  -> Success!"
            return 0
        fi
        echo "  -> Not ready yet. Retrying in ${wait_time}s... ($i/$retries)"
        sleep "$wait_time"
    done

    # Handle float/int multiplication safely
    local total_time
    total_time=$(awk "BEGIN {print $retries * $wait_time}")

    # If the loop finishes without success, throw an error and halt the script
    echo "Error: Timed out waiting for ${message} after ${total_time} seconds." >&2
    return 1
}
