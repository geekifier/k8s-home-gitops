#!/usr/bin/env bash
# Rejects staged *.sops.yaml files that still hold plaintext. Reads the staged
# blob, never decrypts, and prints key paths only (never values). Mirrors
# .sops.yaml: files under kubernetes/ and bootstrap/ encrypt data/stringData,
# values.sops.yaml and everything else are encrypted whole.
set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"

# sops leaves empty values as they are.
encrypted='^ENC\[AES256_GCM,data:[^,]*,iv:[^,]+,tag:[^,]+,type:[a-z]+\]$'
plaintext='. != null and . != "" and (tag != "!!str" or (test("'"$encrypted"'") | not))'
partial='((.data // {}) * (.stringData // {})) | to_entries[] | select(.value | ('"$plaintext"')) | .key'
whole='del(.sops) | .. | select(kind == "scalar") | select('"$plaintext"') | path | join(".")'

status=0

for file in "$@"; do
    # The sops config itself
    [[ ${file##*/} == .sops.yaml ]] && continue

    if [[ $file =~ ^(kubernetes|bootstrap)/ && $file != *values.sops.yaml ]]; then
        expr=$partial
    else
        expr=$whole
    fi

    if ! keys=$(git cat-file blob ":${file}" | yq "$expr" 2>&1); then
        echo "${file}: cannot check staged content" >&2
        status=1
    elif [[ -n $keys ]]; then
        echo "${file}: plaintext at: $(tr '\n' ' ' <<<"$keys")" >&2
        status=1
    fi
done

if ((status)); then
    echo "encrypt with 'sops -e -i <file>' or 'sops set', then stage again" >&2
fi
exit "$status"
