#!/usr/bin/env bash
# In case it's not immediately obvious, this is total AI slop. Use with caution :).
#
# Multi-way diff of a HelmRelease's inlined values against past chart versions.
#
# Why this exists: when a HelmRelease inlines a chart's full values file,
# Renovate bumps only the version string. Any upstream default that changed
# underneath an inlined override is silently kept at the old value, with no
# diff to review and no error anywhere. That is how KubeSchedulerDown fired
# for 33 days (see PR #776) -- the chart moved control-plane Services from a
# `jobLabel` label to `app.kubernetes.io/component`, but the pinned
# `jobLabel: jobLabel` override survived the bump and the job label silently
# became the Service name.
#
# The trick is comparing more than two things. A value that still matches some
# OLD chart's default was never a decision -- it rode along in the inlined
# copy. A value that differs from every version ever pinned here is a real
# customization. Only the former is drift.
#
# Every previously pinned version is a baseline, not just the last one: drift
# missed during one upgrade would otherwise be invisible forever after. A value
# copied at 0.44.0 and changed by 0.50.0 differs from both 0.85.8 and its
# immediate predecessor, so a single-baseline run would call it deliberate.
#
# What gets compared is the release's *whole* values stack, not .spec.values:
# Flux merges every valuesFrom source in declaration order and then overlays
# .spec.values on top. Half of cert-manager's values live in a generated
# ConfigMap and half inline, so auditing either half alone reports clean.
#
# Usage:
#   scripts/chart-values-drift.sh <helmrelease.yaml> [--from VER]... [--to VER]
#
#   --from VER        baseline chart version. Repeat or comma-separate for
#                     several. Default: every version the chart source's git
#                     history ever pinned, newest first.
#   --to VER          target chart version (default: the version pinned in the source)
#   --chart URL       chart URL, overriding whatever the HelmRelease resolves to
#   --max-baselines N stop after N auto-detected baselines (default: no cap).
#                     Trading coverage for time downgrades the result to exit 3.
#   --expand          print every reported value in full, and any that does not
#                     fit on one line as a unified diff against the chart
#                     default (- chart, + repo) instead of a 120-character
#                     stub. Long, but the only way to see which keys of a
#                     nested override are actually overrides.
#   --refresh         re-download chart values even if they are cached
#
# Reviewing a Renovate bump before merging it:
#   scripts/chart-values-drift.sh <file> --to <proposed>
#
# Fetched values are cached per chart and version under helm's own cache home
# ($HELM_CACHE_HOME/chart-values-drift, override with $CHART_VALUES_DRIFT_CACHE)
# so `helm env` points at them and whatever cleans helm's cache cleans these
# too. A released version's values.yaml is immutable, so entries never expire;
# without them every rerun re-pulls the same dozen baselines, and releases that
# share a chart source re-pull each other's.
#
# Exit codes:
#   0  clean, and every baseline was read
#   1  stale drift or a shape conflict
#   2  usage or setup error
#   3  nothing found, but coverage was incomplete -- a baseline was capped or
#      unfetchable, or a valuesFrom source could not be read. NOT a clean
#      result: drift older than the omitted versions reads as a customization.

set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
warn() { printf 'warning: %s\n' "$*" >&2; }

for tool in helm yq python3 git; do
    command -v "$tool" >/dev/null || die "$tool is required but not installed"
done

FILE="" TO_VER="" CHART_OVERRIDE="" MAX_BASELINES="" EXPAND="" REFRESH=""
FROM_VERS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)
            [[ -n "${2:-}" ]] || die "--from needs a version"
            IFS=',' read -r -a _split <<< "$2"
            FROM_VERS+=("${_split[@]}")
            shift 2 ;;
        --to)    TO_VER="${2:-}"; shift 2 ;;
        --chart) CHART_OVERRIDE="${2:-}"; shift 2 ;;
        --max-baselines)
            MAX_BASELINES="${2:-}"
            [[ "$MAX_BASELINES" =~ ^[1-9][0-9]*$ ]] || die "--max-baselines needs a positive number"
            shift 2 ;;
        --expand)  EXPAND=1; shift ;;
        --refresh) REFRESH=1; shift ;;
        -h|--help)
            awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
            exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)  FILE="$1"; shift ;;
    esac
done

[[ -n "$FILE" ]] || die "usage: $0 <helmrelease.yaml> [--from VER]... [--to VER]"
[[ -f "$FILE" ]] || die "no such file: $FILE"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
SEARCH_ROOT="$ROOT/kubernetes"; [[ -d "$SEARCH_ROOT" ]] || SEARCH_ROOT="$ROOT"

# git show <sha>:<path> only accepts repo-relative paths, and the chart source is
# often in a directory far from the HelmRelease, so normalize before asking git.
rel() { python3 -c 'import os,sys; print(os.path.relpath(os.path.abspath(sys.argv[1]), sys.argv[2]))' "$1" "$ROOT"; }

hr() {  # yq expression, evaluated against the HelmRelease document
    yq eval -N "select(.kind==\"HelmRelease\") | explode(.) | $1" "$FILE" 2>/dev/null \
        | grep -v '^null$' | head -1 || true
}

src() {  # file kind name expr -- read one field off a named Flux source object
    SRC_KIND="$2" SRC_NAME="$3" yq eval -N \
        "select(.kind==strenv(SRC_KIND) and .metadata.name==strenv(SRC_NAME)) | $4" "$1" 2>/dev/null \
        | grep -v '^null$' | head -1 || true
}

# Locate the file declaring a named source. Only the simplest layout inlines it
# next to the HelmRelease; it is just as often a sibling ocirepository.yaml, a
# Kustomize component shared by a whole namespace (components/repos/app-template
# backs ~20 releases), or another app's directory entirely. Flux resolves these
# by name, so name is the handle here too -- but check the HelmRelease's own file
# first, so an inline source can never be shadowed by a same-named one elsewhere.
find_source_file() {  # kind name [namespace]
    local kind="$1" name="$2" ns="${3:-}" f have
    while IFS= read -r f; do
        [[ -n "$(src "$f" "$kind" "$name" .spec.url)" ]] || continue
        have=$(src "$f" "$kind" "$name" .metadata.namespace)
        # Namespace is usually left to the Kustomization, so an unset one matches.
        [[ -z "$ns" || -z "$have" || "$ns" == "$have" ]] || continue
        printf '%s\n' "$f"
        return 0
    done < <(printf '%s\n' "$FILE"; grep -rl --include='*.yaml' "kind: $kind" "$SEARCH_ROOT" 2>/dev/null)
    return 1
}

# Resolve the chart coordinates and, separately, the file whose git history holds
# the version. Those are not always the same file: with chartRef the version
# lives in the source object, so reading it from the HelmRelease -- which has
# never contained a version string -- would find no baselines at all.
CHART_ARGS=() CHART_DISPLAY="" VERSION_FILE="" VERSION_YQ="" SRC_NAME=""

REF_KIND=$(hr .spec.chartRef.kind)
REF_NAME=$(hr .spec.chartRef.name)
CHART_NAME=$(hr .spec.chart.spec.chart)

# Neither chartRef nor .spec.chart: the source can only be a document in this file.
if [[ -z "$REF_NAME" && -z "$CHART_NAME" ]]; then
    REF_KIND=OCIRepository
    REF_NAME=$(yq eval -N 'select(.kind=="OCIRepository") | .metadata.name' "$FILE" 2>/dev/null \
        | grep -v '^null$' | head -1 || true)
fi

if [[ -n "$REF_NAME" ]]; then
    [[ "$REF_KIND" == "OCIRepository" ]] || die "unsupported chartRef kind: $REF_KIND"
    SRC_FILE=$(find_source_file OCIRepository "$REF_NAME" "$(hr .spec.chartRef.namespace)") \
        || die "chartRef names OCIRepository/$REF_NAME, but no such source exists under $SEARCH_ROOT"
    SRC_NAME="$REF_NAME"
    CHART_ARGS=("$(src "$SRC_FILE" OCIRepository "$REF_NAME" .spec.url)")
    VERSION_FILE="$SRC_FILE"
    VERSION_YQ='select(.kind=="OCIRepository" and .metadata.name==strenv(SRC_NAME)) | .spec.ref.tag'
elif [[ -n "$CHART_NAME" ]]; then
    REPO_KIND=$(hr .spec.chart.spec.sourceRef.kind)
    REPO_NAME=$(hr .spec.chart.spec.sourceRef.name)
    [[ "$REPO_KIND" == "HelmRepository" ]] || die "unsupported sourceRef kind: ${REPO_KIND:-<none>}"
    SRC_FILE=$(find_source_file HelmRepository "$REPO_NAME" "$(hr .spec.chart.spec.sourceRef.namespace)") \
        || die "sourceRef names HelmRepository/$REPO_NAME, but no such source exists under $SEARCH_ROOT"
    SRC_NAME="$REPO_NAME"
    REPO_URL=$(src "$SRC_FILE" HelmRepository "$REPO_NAME" .spec.url)
    if [[ "$REPO_URL" == oci://* ]]; then
        CHART_ARGS=("${REPO_URL%/}/$CHART_NAME")     # an OCI-typed HelmRepository
    else
        CHART_ARGS=("$CHART_NAME" --repo "$REPO_URL")
        CHART_DISPLAY="$CHART_NAME (repo $REPO_URL)"
    fi
    # A classic .spec.chart carries its own version, so this file is the history.
    VERSION_FILE="$FILE"
    VERSION_YQ='select(.kind=="HelmRelease") | explode(.) | .spec.chart.spec.version'
fi

# Values are almost never just .spec.values. Flux stacks every valuesFrom source
# in declaration order and then overlays .spec.values on top -- Helm's MergeMaps,
# where maps merge key by key while lists, scalars and explicit nulls replace
# wholesale. Picking one layer audits a fragment of the release: cert-manager
# keeps six keys in a generated ConfigMap and four inline, so whichever half you
# read, the other half is invisible and the run reports clean.
#
# An unreadable layer is never quietly dropped. A root-merge source could carry
# any key at all, so losing one leaves no partial result worth printing -- that
# is a setup error. A targetPath source is bounded: exactly one path is unknown,
# so that path still gets its existence and shape checked and only its value is
# withheld, which downgrades an otherwise-clean run to exit 3.
L_TARGET=() L_MODE=() L_PATH=() L_DESC=() UNREADABLE=()

# The kustomization declaring the generator is not always the HelmRelease's
# sibling: victoria-metrics keeps the release in app/helm/ and the generator one
# level up in app/. Walk up to the repo root, nearest first -- a kustomization
# reaches its resources by relative path, so the one including this release sits
# at or above its directory, never off to the side.
find_generated_file() {  # configmap-name values-key -> path of the file behind that key
    local name="$1" key="$2" dir kust entry k p
    dir=$(cd "$(dirname "$FILE")" && pwd)
    while [[ "$dir" == "$ROOT"* ]]; do
        for kust in "$dir/kustomization.yaml" "$dir/kustomization.yml"; do
            [[ -f "$kust" ]] || continue
            while IFS= read -r entry; do
                # configMapGenerator file entries are `key=path`, or a bare
                # `path` that kustomize keys by its basename.
                if [[ "$entry" == *=* ]]; then k="${entry%%=*}" p="${entry#*=}"
                else k="${entry##*/}" p="$entry"; fi
                [[ "$k" == "$key" && -f "$dir/$p" ]] || continue
                printf '%s\n' "$dir/$p"
                return 0
            done < <(CM="$name" yq eval -N \
                '.configMapGenerator[]? | select(.name==strenv(CM)) | .files[]?' "$kust" 2>/dev/null)
        done
        [[ "$dir" != "$ROOT" ]] || break
        dir=$(dirname "$dir")
    done
    return 1
}

while IFS=$'\t' read -r vkind vname vkey vpath; do
    [[ -n "$vkind" && -n "$vname" ]] || continue
    label="$vkind/${vname}[$vkey]"
    [[ -z "$vpath" ]] || label="$label -> $vpath"

    found=""
    [[ "$vkind" != "ConfigMap" ]] || found=$(find_generated_file "$vname" "$vkey" || true)
    if [[ -n "$found" ]]; then
        # Without a targetPath the key holds a values document; with one it is a
        # flat string that Flux writes verbatim at that path.
        L_TARGET+=("$vpath") L_PATH+=("$found") L_DESC+=("$label = $(rel "$found")")
        [[ -n "$vpath" ]] && L_MODE+=(text) || L_MODE+=(doc)
        continue
    fi

    if [[ "$vkind" == "Secret" ]]; then
        why="Secrets are encrypted at rest here, so their values are not in git"
    else
        why="no configMapGenerator under $(rel "$(dirname "$FILE")") or its parents produces key $vkey"
    fi
    [[ -n "$vpath" ]] || die "cannot read $label, which Flux merges at the values root.
       $why.
       A root source can carry any key, so without it every value in this
       release is unaccounted for -- there is no partial audit worth printing."
    L_TARGET+=("$vpath") L_MODE+=(unreadable) L_PATH+=("") L_DESC+=("$label = <unreadable: $why>")
    UNREADABLE+=("$vpath")
done < <(yq eval -N 'select(.kind=="HelmRelease") | explode(.) | .spec.valuesFrom[]?
    | [.kind, .name, (.valuesKey // "values.yaml"), (.targetPath // "")] | @tsv' "$FILE" 2>/dev/null)

INLINE=$(hr .spec.values)

[[ -z "$CHART_OVERRIDE" ]] || { CHART_ARGS=("$CHART_OVERRIDE"); CHART_DISPLAY="$CHART_OVERRIDE"; }
[[ ${#CHART_ARGS[@]} -gt 0 && -n "${CHART_ARGS[0]}" ]] \
    || die "could not resolve a chart source from $FILE (pass --chart oci://...)"
[[ -n "$CHART_DISPLAY" ]] || CHART_DISPLAY="${CHART_ARGS[0]}"

version_at() {  # yaml on stdin -> the version it pins, digest suffix stripped
    local v
    v=$(SRC_NAME="$SRC_NAME" yq eval -N "$VERSION_YQ" - 2>/dev/null | grep -v '^null$' | head -1 || true)
    printf '%s\n' "${v%%@*}"
}

PINNED=""
[[ -z "$VERSION_FILE" ]] || PINNED=$(version_at < "$VERSION_FILE")
[[ -n "$TO_VER" ]] || TO_VER="$PINNED"
[[ -n "$TO_VER" ]] || die "could not determine target version (pass --to)"

# Auto-detect baselines: every distinct version the source ever pinned, newest
# first. Taking only the most recent one would give drift a single-upgrade
# detection window -- anything missed once could never be found again.
#
# For a source shared across releases (app-template) this is every version the
# cluster ever ran, not just the ones this release saw. That is a superset, and
# the right one: a value copied from a default that only ever shipped in a
# version some *other* release pinned is still a value nobody here chose.
AUTO_DETECTED=0
SKIPPED=()
if [[ ${#FROM_VERS[@]} -eq 0 ]]; then
    AUTO_DETECTED=1
    [[ -n "$VERSION_FILE" ]] || die "no chart source to read version history from (pass --from)"
    VERSION_REL=$(rel "$VERSION_FILE")
    while read -r sha; do
        t=$(git -C "$ROOT" show "$sha:$VERSION_REL" 2>/dev/null | version_at)
        [[ -n "$t" && "$t" != "$TO_VER" ]] || continue
        for seen in ${FROM_VERS[@]+"${FROM_VERS[@]}"} ${SKIPPED[@]+"${SKIPPED[@]}"}; do
            [[ "$seen" == "$t" ]] && continue 2
        done
        if [[ -z "$MAX_BASELINES" || ${#FROM_VERS[@]} -lt $MAX_BASELINES ]]; then
            FROM_VERS+=("$t")
        else
            SKIPPED+=("$t")
        fi
    done < <(git -C "$ROOT" log --format='%H' -- "$VERSION_REL" 2>/dev/null)
fi
[[ ${#FROM_VERS[@]} -gt 0 ]] || die "$(rel "${VERSION_FILE:-$FILE}") has only ever pinned $TO_VER.
       With no upgrade behind it there is no older default to have drifted from
       (pass --from to compare against a version this repo never ran)."

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

printf 'chart:     %s\n' "$CHART_DISPLAY"
# Name the version-bearing file when it is not this one -- the versions below
# come from its git history, not the HelmRelease's, which is surprising until
# you see it spelled out (and is why a chartRef release finds baselines at all).
[[ -z "$VERSION_FILE" || "$VERSION_FILE" == "$FILE" ]] || printf 'history:   %s\n' "$(rel "$VERSION_FILE")"
# List the stack in merge order. Which layer a value came from decides whether a
# finding is even actionable, and the order decides which layer won.
if [[ ${#L_DESC[@]} -gt 0 ]]; then
    printf 'values:    %s\n' "${L_DESC[0]}"
    for ((li = 1; li < ${#L_DESC[@]}; li++)); do printf '           %s\n' "${L_DESC[$li]}"; done
    [[ -z "$INLINE" ]] || printf '           %s\n' "inline .spec.values (overlaid last)"
fi
printf 'baselines: %s%s\n' "${FROM_VERS[*]}" "$([[ $AUTO_DETECTED -eq 1 ]] && echo ' (from git history)')"
printf 'target:    %s%s\n\n' "$TO_VER" "$([[ "$TO_VER" == "$PINNED" ]] && echo ' (pinned in file)')"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    warn "--max-baselines=$MAX_BASELINES: NOT compared against ${SKIPPED[*]}"
    warn "drift older than ${FROM_VERS[-1]} will read as a customization"
fi

[[ ${#L_DESC[@]} -gt 0 || -n "$INLINE" ]] || die "no .spec.values in $FILE, and no valuesFrom source that
       resolves to a values file in this repo"

# Hand the layers to python in merge order. Each is a (targetPath, mode, path)
# triple; the mode says how to read it, and an empty targetPath means the layer
# merges at the root. Root layers are pre-converted to JSON because python3
# here is stdlib-only and cannot parse YAML itself.
LAYERS=()
for ((li = 0; li < ${#L_MODE[@]}; li++)); do
    if [[ "${L_MODE[$li]}" == "doc" ]]; then
        yq eval -o=json '.' "${L_PATH[$li]}" > "$WORK/layer-$li.json" \
            || die "failed to parse ${L_PATH[$li]}"
        LAYERS+=("" doc "$WORK/layer-$li.json")
    else
        LAYERS+=("${L_TARGET[$li]}" "${L_MODE[$li]}" "${L_PATH[$li]}")
    fi
done
if [[ -n "$INLINE" ]]; then
    # The HelmRelease may carry YAML anchors, so explode before extracting.
    yq eval 'select(.kind=="HelmRelease") | explode(.) | .spec.values' -o=json "$FILE" > "$WORK/inline.json" \
        || die "failed to extract .spec.values from $FILE"
    LAYERS+=("" doc "$WORK/inline.json")
fi

# Marks a value Flux takes from a source this script cannot read. It has to be
# a plain string to survive the round-trip through JSON, and becomes a sentinel
# again in the audit below. Spelled out in full so that if one ever did leak
# into a report it would read as an explanation rather than as a value.
UNREADABLE_MARK='<from a valuesFrom source that is not in git>'

UNREADABLE_MARK="$UNREADABLE_MARK" python3 - "$WORK/repo.json" "${LAYERS[@]}" <<'PYEOF' || exit 2
import json, os, sys

out_path, layers = sys.argv[1], sys.argv[2:]
MARK = os.environ["UNREADABLE_MARK"]

def bad(msg):
    sys.stderr.write(f"error: {msg}\n")
    sys.exit(2)

def merge(a, b):
    """Helm's transform.MergeMaps -- what the helm-controller stacks valuesFrom
    sources and .spec.values with. Maps merge key by key; lists, scalars and
    explicit nulls replace wholesale.

    This is merge, not coalesce. A null in a later layer really does overwrite
    an earlier map here, and only acquires its delete-the-chart's-key meaning
    afterwards, when Helm coalesces the finished result with the chart defaults
    -- which is the reading conflict() downstream is written against."""
    out = dict(a)
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = merge(out[k], v)
        else:
            out[k] = v
    return out

def split_path(p):
    """targetPath is Helm strvals syntax: dot-separated, backslash escapes a
    literal dot. strvals also indexes lists, but nothing here uses that and
    guessing at it would silently write to the wrong place."""
    if "[" in p:
        bad(f"targetPath {p!r} indexes a list, which this script does not model")
    parts, cur, esc = [], "", False
    for ch in p:
        if esc:
            cur, esc = cur + ch, False
        elif ch == "\\":
            esc = True
        elif ch == ".":
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    if not all(parts):
        bad(f"malformed targetPath {p!r}")
    return parts

def put(root, path, value):
    node = root
    parts = split_path(path)
    for k in parts[:-1]:
        if not isinstance(node.get(k), dict):
            node[k] = {}
        node = node[k]
    node[parts[-1]] = value

result = {}
for target, mode, path in zip(layers[::3], layers[1::3], layers[2::3]):
    if mode == "doc":
        with open(path) as fh:
            # An empty values.yaml and an absent .spec.values both read as null.
            result = merge(result, json.load(fh) or {})
    elif mode == "text":
        # A targetPath value is always a string: Flux feeds the key's raw bytes
        # to strvals.ParseIntoString, which never parses them as YAML.
        with open(path) as fh:
            put(result, target, fh.read().rstrip("\n"))
    else:
        put(result, target, MARK)

with open(out_path, "w") as fh:
    json.dump(result, fh)
PYEOF

[[ -s "$WORK/repo.json" ]] && [[ "$(cat "$WORK/repo.json")" != "null" ]] \
    && [[ "$(cat "$WORK/repo.json")" != "{}" ]] || die "no values found for $FILE"

# Cache fetched values per chart and version. A run compares against every
# version the source ever pinned, so a chart with a long history costs a dozen
# registry round trips -- paid again on the next run, and again by every other
# release sharing that source (app-template backs ~20 of them). A released
# version's values.yaml is immutable, so a hit needs no revalidation.
CACHE_ROOT="${CHART_VALUES_DRIFT_CACHE:-}"
if [[ -z "$CACHE_ROOT" ]]; then
    # helm knows where its cache belongs on this platform; only guess if asking
    # fails, and follow the same XDG default helm itself uses.
    HELM_CACHE=$(helm env HELM_CACHE_HOME 2>/dev/null | tail -1)
    [[ "$HELM_CACHE" == /* ]] || HELM_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/helm"
    CACHE_ROOT="$HELM_CACHE/chart-values-drift"
fi
# Key on the full coordinates, not the chart name: an OCI chart and a `--repo`
# chart can share a name, and two repos can ship the same name and version with
# different defaults. The name is kept in the path only so the directory is
# browsable; the hash is what makes it unique.
CACHE_DIR="$CACHE_ROOT/$(printf '%s' "${CHART_ARGS[0]##*/}" | tr -c 'A-Za-z0-9._-' '_')-$(
    printf '%s\n' "${CHART_ARGS[@]}" \
        | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
CACHE_OK=1
mkdir -p "$CACHE_DIR" 2>/dev/null || { warn "cannot write $CACHE_DIR -- fetching uncached"; CACHE_OK=""; }

usable() {  # does this dump hold an actual values document?
    # yq turns an empty stream into the literal `null`, which json.load reads as
    # an empty values file -- a baseline that matches nothing and quietly weakens
    # the audit. Treat it as the failed fetch it is, on read as well as on write:
    # a cache entry that somehow ended up empty has to miss, not silently pass.
    [[ -s "$1" && "$(cat "$1")" != "null" ]]
}

fetch() {  # version slot
    local entry="$CACHE_DIR/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._+-' '_').json"
    if [[ -z "$REFRESH" && -n "$CACHE_OK" ]] && usable "$entry"; then
        cp "$entry" "$WORK/$2.json"
        printf 'cached   %s\n' "$1" >&2
        return 0
    fi
    printf 'fetching %s ...\n' "$1" >&2
    # For OCI charts helm writes its pull banner to stdout, not stderr, so it
    # arrives in-band ahead of the values. Left alone it parses as two top-level
    # keys -- phantom chart defaults that show up as "new keys" on every run, and
    # enough content to defeat the empty-stream guard below. Strip it only while
    # still in the header, so a chart may legitimately own either key name.
    helm show values "${CHART_ARGS[@]}" --version "$1" 2>/dev/null \
        | awk 'BEGIN { hdr = 1 } hdr && /^(Pulled|Digest): / { next } { hdr = 0; print }' \
        | yq eval -o=json - > "$WORK/$2.json" || return 1
    usable "$WORK/$2.json" || return 1
    # Land the entry by rename, never by writing in place: a run killed mid-write
    # would otherwise leave a truncated but parseable baseline behind, and the
    # next run would read it as a smaller chart and call the missing keys drift.
    if [[ -n "$CACHE_OK" ]] && cp "$WORK/$2.json" "$entry.$$" 2>/dev/null; then
        mv "$entry.$$" "$entry" 2>/dev/null || rm -f "$entry.$$"
    fi
    return 0
}

if ! fetch "$TO_VER" new; then
    # Distinguish "could not read the chart" from "the chart has no defaults".
    # The second is not a failure, it means this audit cannot say anything:
    # with no defaults there is nothing for an inlined value to have drifted
    # from, and every key in the release is a repo-only extra by definition.
    if helm show chart "${CHART_ARGS[@]}" --version "$TO_VER" >/dev/null 2>&1; then
        die "$CHART_DISPLAY $TO_VER ships an empty values.yaml, so it has no defaults to compare against.
       Value drift is undefined for such a chart -- every key here is a repo-only
       extra, not a copied default. app-template is one of these."
    fi
    die "helm show values failed for $CHART_DISPLAY version $TO_VER"
fi

# A version pinned long ago may have been yanked from the registry. That is not
# fatal when the baseline list was auto-detected -- drop it, but count it against
# the run's coverage so a partial audit can never pass for a clean one.
RESOLVED=()
i=0
for ver in "${FROM_VERS[@]}"; do
    if fetch "$ver" "base-$i"; then
        RESOLVED+=("$ver")
        i=$((i + 1))
    elif [[ $AUTO_DETECTED -eq 1 ]]; then
        warn "could not fetch baseline $ver -- skipping it"
        SKIPPED+=("$ver")
    else
        die "helm show values failed for $CHART_DISPLAY version $ver"
    fi
done
[[ ${#RESOLVED[@]} -gt 0 ]] || die "none of the baseline versions could be fetched"
printf '\n' >&2

BASELINE_VERS="${RESOLVED[*]}" OMITTED_VERS="${SKIPPED[*]-}" TO_VER="$TO_VER" \
UNREADABLE_MARK="$UNREADABLE_MARK" UNREADABLE_PATHS="${UNREADABLE[*]-}" EXPAND="${EXPAND:-}" \
python3 - "$WORK" <<'PYEOF'
import difflib, json, os, sys

work = sys.argv[1]
TO_VER = os.environ["TO_VER"]
BASELINE_VERS = os.environ["BASELINE_VERS"].split()
OMITTED_VERS = os.environ.get("OMITTED_VERS", "").split()
UNREADABLE_MARK = os.environ["UNREADABLE_MARK"]
UNREADABLE_PATHS = os.environ.get("UNREADABLE_PATHS", "").split()
EXPAND = os.environ.get("EXPAND") == "1"
MISSING = object()
UNKNOWN = object()   # a value Flux takes from a source that is not in git
CONTAINER = ("map", "list")

def join(prefix, k):
    """Build a path segment. Keys may themselves contain dots -- 0.85.x names
    rule groups things like `general.rules` -- so a naive dot-join makes
    groups["general.rules"].rules collide with groups.general.rules and invents
    differences that do not exist. Bracket-quote any key that is not a plain
    identifier so every path stays unambiguous."""
    k = str(k)
    if any(c in k for c in '.[]"'):
        return f'{prefix}["{k}"]' if prefix else f'["{k}"]'
    return f"{prefix}.{k}" if prefix else k

def kind(v):
    if v is UNKNOWN:
        # Not a guess: a targetPath value is whatever bytes the key holds, and
        # Flux writes it through strvals.ParseIntoString, which always produces
        # a string. So the type is known even when the value is not.
        return "scalar"
    if v is None:
        return "null"
    if isinstance(v, dict):
        return "map"
    if isinstance(v, list):
        return "list"
    return "scalar"

def walk(obj, prefix="", nodes=None, leaves=None):
    """Record every node, not just the leaves. The shape checks need the
    containers too: a map in the repo sitting where the chart now has a scalar
    is invisible if you only ever compare leaf paths -- it flattens into a pile
    of removed children and a brand new key, and nothing looks wrong.

    Lists are terminal. Helm replaces a list wholesale instead of merging it
    element by element, so an inlined `items: [a]` over a chart default that
    grew to `[a, b]` renders `[a]` -- b is suppressed, not inherited. Walking
    into the elements compares items[0], finds it equal, and then reports
    items[1] as a new key the release picks up for free, which is the exact
    opposite of what Helm does. Comparing the list as one value is the only
    reading that matches the merge, and it makes that case stale drift: the
    repo list still matches an old default and differs from the new one."""
    if nodes is None:
        nodes, leaves = {}, {}
    if prefix:
        nodes[prefix] = obj
    if isinstance(obj, dict) and obj:
        for k, v in obj.items():
            walk(v, join(prefix, k), nodes, leaves)
    elif prefix:
        leaves[prefix] = obj  # scalars, nulls, lists, and empty maps
    return nodes, leaves

def load(name):
    with open(os.path.join(work, f"{name}.json")) as fh:
        return walk(json.load(fh) or {})

repo_nodes, repo = load("repo")
new_nodes, new = load("new")

# Turn the marks back into a sentinel. Only the *value* of such a path is out
# of reach -- the path itself and its type are still known, so it keeps its
# existence and shape checks and merely sits out value comparison.
for table in (repo_nodes, repo):
    for path, v in table.items():
        if v == UNREADABLE_MARK:
            table[path] = UNKNOWN
baselines = [(ver, *load(f"base-{i}")) for i, ver in enumerate(BASELINE_VERS)]

def eq(a, b):
    """Value equality, for leaves the shape pass has already cleared.

    null, {} and [] are NOT interchangeable to Helm -- conflict() owns every
    pair where either side is a container, including the empty ones. What is
    left here is a repo container sitting over a chart-side null: the chart
    declares nothing, the repo configures nothing, and there is no type for
    the templates to disagree about. Reporting that as a difference is the
    false positive this exists to avoid."""
    if a is MISSING or b is MISSING:
        return False
    empty = (None, {}, [])
    if a in empty and b in empty:
        return True
    return a == b

def describe(v, k):
    return f"empty {k}" if k in CONTAINER and not v else k

def conflict(rv, nv):
    """Why the inlined value cannot merge cleanly into the target chart, or None.

    This turns on Helm's coalescing rules, which are easy to get backwards:
      * an explicit null DELETES the chart's key -- it does not mean "unset",
        so `foo: null` over a new `foo: {enabled: true}` silently suppresses it
      * maps merge key by key, so {} over a map leaves the chart's defaults intact
      * lists are replaced wholesale, so [] over a list wipes the chart's entries

    An empty chart-side default is not a free pass either: the override still
    survives merging with its own type, so `foo: {a: 1}` over a chart's `foo: []`
    renders a map where the templates now expect a list."""
    kr, kn = kind(rv), kind(nv)
    if kr not in CONTAINER and kn not in CONTAINER:
        return None                       # leaf vs leaf -- the value pass owns it
    if kr == kn:
        # Same type. Maps merge, so an empty one is inert; lists are replaced
        # wholesale, so an empty one wipes whatever the chart shipped.
        if kr == "list" and not rv and nv:
            return f"empty list replaces the chart's {len(nv)}-item default"
        return None
    if kn == "null":
        return None                       # chart declares nothing; repo configures it
    if kr == "null":
        if not nv:
            return f"null deletes the key; the chart declares an empty {kn}"
        size = f"{len(nv)}-key map" if kn == "map" else f"{len(nv)}-item list"
        return f"null deletes the {size} the chart now defaults to"
    tail = " (chart default is empty)" if kn in CONTAINER and not nv else ""
    return f"{describe(rv, kr)} in repo, {kn} in chart{tail}"

# Shape conflicts first, parents before children, so a restructured subtree is
# reported once at its root instead of as a spray of removed leaves.
shape, blocked = [], []

def under_blocked(path):
    return any(path == b or path.startswith(b + ".") or path.startswith(b + "[") for b in blocked)

for path in sorted(repo_nodes, key=lambda p: (p.count(".") + p.count("["), p)):
    if under_blocked(path):
        continue
    nv = new_nodes.get(path, MISSING)
    if nv is MISSING:
        continue
    reason = conflict(repo_nodes[path], nv)
    if reason:
        shape.append((path, reason, repo_nodes[path], nv))
        blocked.append(path)

stale, removed, custom = [], [], []

for path, rv in repo.items():
    if under_blocked(path):
        continue
    nv = new.get(path, MISSING)
    if nv is MISSING:
        if path in new_nodes:
            continue                     # chart grew a subtree here; conflict() ruled on it
        if any(path in leaves for _, _, leaves in baselines):
            removed.append((path, rv))   # chart dropped the key
        continue                         # repo-only extra config, not chart-derived
    if rv is UNKNOWN:
        continue                         # value withheld; the shape pass vetted the path
    if eq(rv, nv):
        continue
    match = next((ver for ver, _, leaves in baselines
                  if eq(rv, leaves.get(path, MISSING)) and not eq(leaves[path], nv)), None)
    if match:
        stale.append((path, rv, nv, match))  # the drift class
    else:
        custom.append((path, rv, nv))        # differs from every version pinned here

# Keys the new chart added that the inlined copy predates.
added = [k for k in new
         if k not in repo and not under_blocked(k)
         and not any(k in leaves for _, _, leaves in baselines)]

label = f"{TO_VER} default:"

def show(v):
    if v is MISSING:
        return "<absent>"
    if v is UNKNOWN:
        return "<not in git>"
    s = json.dumps(v)
    if len(s) <= 120 or EXPAND:
        return s
    # Lists are compared whole, so a truncated one hides the very thing being
    # reported. Keep the count visible even when the contents are cut off.
    return s[:117] + "..." + (f" ({len(v)} items)" if isinstance(v, list) else "")

def render(v):
    """A value as the lines --expand prints it on.

    Multi-line strings print as themselves: json.dumps would fold an inlined
    alertmanager template or scrape config into a single \\n-escaped line, and
    an unreadable one-liner is what --expand exists to get rid of."""
    if v is MISSING:
        return ["<absent>"]
    if v is UNKNOWN:
        return ["<not in git>"]
    if isinstance(v, str) and "\n" in v:
        return v.splitlines()
    return json.dumps(v, indent=2).splitlines()

def sides(rlabel, rv, nv, note=""):
    """The repo value against the target chart's default, as a printable block.

    By default each side is one truncated line: a finding is a pointer to go
    look, and dumping a 40-key map twice per finding buries the list of
    findings itself.

    --expand prints them in full, and anything that does not fit on one line as
    a unified diff with complete context (- chart, + repo). Two separate JSON
    dumps make you scan them side by side to answer the only question a nested
    override raises -- which of these keys did we actually change? -- and a
    truncated pair cannot answer it at all. One document where every line is
    shared, chart-only or repo-only answers it by eye."""
    if EXPAND:
        chart, repo = render(nv), render(rv)
        if len(chart) > 1 or len(repo) > 1:
            body = list(difflib.unified_diff(
                chart, repo, fromfile=f"{TO_VER} default", tofile="repo",
                lineterm="", n=max(len(chart), len(repo))))
            # An empty diff means the two render identically -- only possible
            # for a shape conflict, whose reason line already says everything.
            if body:
                return "".join(f"      {line}\n" for line in body)
    return f"      {rlabel:<10}{show(rv)}{note}\n      {label:<16}{show(nv)}\n"

def suppressed(r, n):
    """For a list, what the release loses by overriding it. Helm keeps the repo
    list verbatim, so anything the chart added is silently dropped -- and that
    is the whole reason a stale list matters more than a stale scalar."""
    if not isinstance(r, list) or not isinstance(n, list):
        return ""
    gained = [v for v in n if v not in r]
    if not gained:
        return "      note:     list is replaced wholesale, not merged\n"
    return (f"      note:     replaces the list wholesale -- {len(gained)} chart-added "
            f"entr{'y' if len(gained) == 1 else 'ies'} will not render\n")

def header(title, n):
    print(f"\n{'=' * 72}\n{title}  ({n})\n{'=' * 72}")

header(f"STALE DRIFT -- still at an older chart default, changed in {TO_VER}", len(stale))
if stale:
    print("These were never chosen; they rode along in the inlined copy.\n")
    for p, r, n, ver in stale:
        # Which baseline the repo value matches is the finding. A diff has
        # nowhere to put that, so in --expand it moves up to the path line.
        origin = f"   (= the {ver} default)"
        print(f"  {p}{origin if EXPAND else ''}\n"
              f"{sides('now:', r, n, '' if EXPAND else origin)}{suppressed(r, n)}")
else:
    print("\n  none\n")

header(f"RESTRUCTURED -- shape conflicts with {TO_VER}", len(shape))
if shape:
    print("The override is ignored, silences a chart default, or conflicts with it.\n")
    for p, reason, r, n in shape:
        print(f"  {p}  --  {reason}\n{sides('repo:', r, n)}")
else:
    print("\n  none\n")

header(f"REMOVED -- key existed in an older chart, gone in {TO_VER}", len(removed))
if removed:
    print("Dead config: the chart no longer reads these.\n")
    for p, r in removed:
        lines = render(r) if EXPAND else [show(r)]
        if len(lines) > 1:
            print(f"  {p} =\n" + "".join(f"      {l}\n" for l in lines))
        else:
            print(f"  {p} = {lines[0]}")
    print()
else:
    print("\n  none\n")

header("CUSTOMIZATIONS -- deliberate, differs from every version pinned here", len(custom))
print("Review only if a listed default looks newly relevant.\n")
for p, r, n in custom:
    print(f"  {p}\n{sides('repo:', r, n)}")

print(f"\n{'=' * 72}")
print(f"{len(stale)} stale, {len(shape)} restructured, {len(removed)} removed, "
      f"{len(custom)} custom, {len(added)} new keys not in the inlined copy")
print(f"baselines compared: {', '.join(BASELINE_VERS)}")
if OMITTED_VERS:
    print(f"NOT compared:       {', '.join(OMITTED_VERS)}")
if UNREADABLE_PATHS:
    print(f"values not read:    {', '.join(UNREADABLE_PATHS)}")
print("=" * 72)
if added:
    print("\nNew keys added by the chart (inheriting defaults; informational):")
    shown = sorted(added) if EXPAND else sorted(added)[:15]
    for k in shown:
        print(f"  {k}")
    if len(added) > len(shown):
        print(f"  ... and {len(added) - len(shown)} more (--expand lists them all)")

if stale or shape:
    print("\nStale drift or a restructured key was found -- verify each against the")
    print("cluster before assuming intent is still honored. A silently-ignored")
    print("override looks identical to a working one in git.")
    sys.exit(1)

# Nothing found, but something went unread -- drift predating an omitted
# baseline looks like a customization, and a withheld value cannot be compared
# at all. "Clean" would be a lie to anything reading the exit code, so say
# "incomplete" in a way scripts can see.
gaps = []
if OMITTED_VERS:
    gaps.append(f"{', '.join(OMITTED_VERS)} "
                f"{'was' if len(OMITTED_VERS) == 1 else 'were'} not read")
if UNREADABLE_PATHS:
    gaps.append(f"{', '.join(UNREADABLE_PATHS)} "
                f"{'comes' if len(UNREADABLE_PATHS) == 1 else 'come'} from a valuesFrom "
                f"source that is not in git")
if gaps:
    print(f"\nINCOMPLETE: no drift found against {len(BASELINE_VERS)} baselines, "
          f"but {', and '.join(gaps)}.")
    print("This run cannot tell you the values are clean. Exiting 3.")
    sys.exit(3)
PYEOF
