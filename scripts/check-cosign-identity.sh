#!/usr/bin/env bash
# Rejects staged manifests whose cosign `verify` blocks lack matchOIDCIdentity.
# source-controller cannot verify Sigstore bundle signatures without an
# identity, so such sources stall on their last verified artifact.
set -Eeuo pipefail

cd "$(git rev-parse --show-toplevel)"

missing='(select(tag == "!!map") | .metadata.name // "") as $name
  | .. | select(tag == "!!map" and .provider == "cosign")
  | select((.matchOIDCIdentity // []) | length == 0)
  | $name + " (" + (path | join(".")) + ")"'

status=0

for file in "$@"; do
    if ! hits=$(git cat-file blob ":${file}" | yq "$missing" 2>&1); then
        echo "${file}: cannot check staged content" >&2
        status=1
    elif [[ -n $hits ]]; then
        echo "${file}: cosign verify without matchOIDCIdentity: $(tr '\n' ' ' <<<"$hits")" >&2
        status=1
    fi
done

if ((status)); then
    echo "add verify.matchOIDCIdentity with the publisher's issuer and signing workflow subject" >&2
fi
exit "$status"
