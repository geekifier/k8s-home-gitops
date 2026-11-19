#!/usr/bin/env bash
# Print reference-only dummies for `flate --supply -`.
#
# flate cannot read SOPS-encrypted keys, so postBuild.substituteFrom variables
# backed by them would render empty. For every Secret/ConfigMap a Flux
# Kustomization substitutes from, emit its encrypted key names (read from the
# plaintext SOPS structure, never decrypted) in the Kustomization's namespace,
# valued sops-<key-in-kebab-case>: a DNS-safe label that stays recognizable.
#
# Usage: scripts/flate-supply.sh [cluster-path] | flate <cmd> --supply - ...
set -Eeuo pipefail

cd "$(git -C "$(dirname "${0}")" rev-parse --show-toplevel)"
cluster="${1:-kubernetes/flux/cluster}"

err="$(mktemp "${TMPDIR:-/tmp}/flate-supply.XXXXXX")"
trap 'rm -f "${err}"' EXIT

# Kustomizations as Flux sees them (after parent patches) -> "<kind> <name> <namespace>"
if ! rendered="$(flate build all --path "${cluster}" --only-kinds Kustomization --no-progress 2>"${err}")"; then
    cat "${err}" >&2
    exit 1
fi
# shellcheck disable=SC2016 # yq variables, not shell
refs="$(yq -N 'select(.spec.postBuild.substituteFrom) | .metadata.namespace as $ns
    | .spec.postBuild.substituteFrom[] | .kind + " " + .name + " " + $ns' <<<"${rendered}" | sort -u)"

# Encrypted keys of every SOPS Secret/ConfigMap -> "<kind> <name> <key>"
# shellcheck disable=SC2016 # yq variables, not shell
keys="$(find kubernetes -name '*.sops.yaml' -print0 | xargs -0 yq -N '
    select(.kind == "Secret" or .kind == "ConfigMap") | .kind as $k | .metadata.name as $n
    | ((.stringData // {}) * (.data // {})) | to_entries[]
    | select(.value | test("^ENC\[")) | $k + " " + $n + " " + .key' | sort -u)"

while read -r kind name ns; do
    [[ -n "${kind}" ]] || continue
    encrypted="$(awk -v k="${kind}" -v n="${name}" '$1 == k && $2 == n { print $3 }' <<<"${keys}" | sort -u)"
    [[ -n "${encrypted}" ]] || continue # plaintext source: flate reads it already

    field="data"
    [[ "${kind}" == "Secret" ]] && field="stringData" # Secret data must be base64
    printf -- '---\napiVersion: v1\nkind: %s\nmetadata:\n  name: %s\n  namespace: %s\n%s:\n' \
        "${kind}" "${name}" "${ns}" "${field}"
    while read -r key; do
        printf '  %s: "sops-%s"\n' "${key}" "$(tr '[:upper:]_' '[:lower:]-' <<<"${key}")"
    done <<<"${encrypted}"
done <<<"${refs}"
