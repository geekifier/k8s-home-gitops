#!/usr/bin/env bash
# Keeps agent context lean: caps the always-loaded AGENTS.md and rejects large
# non-code files left in the search path (tracked or untracked, not ignored).
# --warn reports violations without failing.
set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"

max_agents_lines=150
max_bytes=$((200 * 1024))
exempt_dir="kubernetes/apps/observability/grafana-dashboards/dashboards/json/"
code_ext='\.(ya?ml|sh|bash|py|go|ts|js|mjs|toml|tpl|cue|jsonnet|lua|rego|tf|hcl)$'

status=0

if [[ -f AGENTS.md ]]; then
    lines=$(wc -l <AGENTS.md)
    if ((lines > max_agents_lines)); then
        echo "AGENTS.md: ${lines} lines (max ${max_agents_lines}); move area-specific rules out" >&2
        status=1
    fi
fi

while IFS= read -r -d '' file; do
    [[ -f $file ]] || continue
    [[ $file == "$exempt_dir"* || $file =~ $code_ext ]] && continue
    size=$(wc -c <"$file")
    if ((size > max_bytes)); then
        echo "${file}: $((size / 1024)) KiB (max $((max_bytes / 1024))); move to .private/ or gitignore it" >&2
        status=1
    fi
done < <(git ls-files -z --cached --others --exclude-standard)

if ((status)) && [[ ${1:-} == --warn ]]; then
    echo "context budget exceeded (warning only)" >&2
    exit 0
fi
exit "$status"
