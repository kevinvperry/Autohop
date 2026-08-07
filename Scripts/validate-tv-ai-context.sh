#!/bin/bash
set -euo pipefail

# AI CONTEXT — Enforces AI-readable ownership headers for every tvOS Swift
# runtime and test source. Apple plist/entitlement/asset formats cannot safely
# contain comments; TV/AI_CONTEXT.md documents those structured files instead.

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

missing=()
while IFS= read -r source_file; do
    if ! grep -q "AI CONTEXT" "$source_file"; then
        missing+=("$source_file")
    fi
done < <(find TV TVTests -type f -name '*.swift' -print | sort)

if (( ${#missing[@]} > 0 )); then
    echo "Missing AI CONTEXT headers in tvOS Swift files:"
    printf '  %s\n' "${missing[@]}"
    exit 1
fi

echo "tvOS AI CONTEXT header check passed."
