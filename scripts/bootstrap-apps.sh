#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# Namespaces to be applied before the SOPS secrets are installed
function apply_namespaces() {
    log debug "Applying namespaces"

    local -r apps_dir="${ROOT_DIR}/kubernetes/apps"

    if [[ ! -d "${apps_dir}" ]]; then
        log error "Directory does not exist" "directory=${apps_dir}"
    fi

    for app in "${apps_dir}"/*/; do
        namespace=$(basename "${app}")

        # Check if the namespace resources are up-to-date
        if kubectl get namespace "${namespace}" &>/dev/null; then
            log info "Namespace resource is up-to-date" "resource=${namespace}"
            continue
        fi

        # Apply the namespace resources
        if kubectl create namespace "${namespace}" --dry-run=client --output=yaml |
            kubectl apply --server-side --filename - &>/dev/null; then
            log info "Namespace resource applied" "resource=${namespace}"
        else
            log error "Failed to apply namespace resource" "resource=${namespace}"
        fi
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    local -r secrets=(
        "${ROOT_DIR}/bootstrap/github-deploy-key.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/common/cluster-secrets.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/common/sops-age.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace flux-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace flux-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done
}

# CRDs to be applied before the helmfile charts are installed, so Flux Kustomizations using them need
# no dependsOn. Each chart's CRDs are rendered at its OCIRepository tag with its HelmRelease values;
# the HelmRelease then upgrades them.
function apply_crds() {
    log debug "Applying CRDs"

    local -r charts=(
        "${ROOT_DIR}/kubernetes/apps/network/envoy-gateway/app/helmrelease.yaml"
        "${ROOT_DIR}/kubernetes/apps/observability/grafana-operator/app/helmrelease.yaml"
        "${ROOT_DIR}/kubernetes/apps/observability/prometheus-operator-crds/app/helmrelease.yaml"
        "${ROOT_DIR}/kubernetes/apps/observability/victoria-metrics/app/helm/helmrelease.yaml"
    )

    local url tag manifest
    for chart in "${charts[@]}"; do
        url="$(yq eval 'select(.kind == "OCIRepository") | .spec.url' "${chart}")"
        tag="$(yq eval 'select(.kind == "OCIRepository") | .spec.ref.tag' "${chart}")"
        # --include-crds covers crds/ directories; templated CRDs render with the chart
        if ! manifest="$(helm template crds "${url}" --version "${tag}" --include-crds --no-hooks \
            --values <(yq eval 'select(.kind == "HelmRelease") | explode(.) | .spec.values // {}' "${chart}") 2>/dev/null |
            yq eval 'select(.kind == "CustomResourceDefinition")' -)" || [[ -z "${manifest}" ]]; then
            log error "Failed to render chart CRDs" "chart=${url}:${tag}"
        fi
        if kubectl diff --filename - <<<"${manifest}" &>/dev/null; then
            log info "CRDs are up-to-date" "chart=${url}:${tag}"
            continue
        fi
        if kubectl apply --server-side --force-conflicts --filename - <<<"${manifest}" &>/dev/null; then
            log info "CRDs applied" "chart=${url}:${tag}"
        else
            log error "Failed to apply CRDs" "chart=${url}:${tag}"
        fi
    done
}

# Apply Helm releases using helmfile
function apply_helm_releases() {
    log debug "Applying Helm releases with helmfile"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! helmfile --file "${helmfile_file}" apply --hide-notes --skip-diff-on-install --suppress-diff --suppress-secrets; then
        log error "Failed to apply Helm releases"
    fi

    log info "Helm releases applied successfully"
}

function main() {
    check_cli helm helmfile kubectl kustomize sops yq

    # Apply resources and Helm releases
    wait_for_nodes
    apply_namespaces
    apply_sops_secrets
    apply_crds
    apply_helm_releases

    log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
