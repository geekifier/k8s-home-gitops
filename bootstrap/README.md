# Bootstrap Helm values

`helmfile.yaml` installs the six core releases in dependency order. Shared
`defaults.yaml` and `templates/` read each release's application manifests under
`kubernetes/apps/<namespace>/<name>/app/`; `ROOT_DIR` is exported by mise and
`scripts/bootstrap-apps.sh`.

- Values come from the HelmRelease's `spec.values`.
- OCI chart URLs and pinned tags come from the OCIRepository in the same
  multi-document `helmrelease.yaml` file.
- Cilium's chart/version come from its HelmRelease and its repository URL from
  the accompanying HelmRepository.
- cert-manager retains the existing bootstrap exception: top-level `resources`
  overrides are left to Flux after bootstrap.

Bootstrap is for new cluster builds and requires inline Helm values in
`spec.values`. `valuesFrom` references are not supported and cause bootstrap to
fail rather than silently omit configuration.

Read-only validation (downloads charts but does not install releases):

```sh
helmfile --file bootstrap/helmfile.yaml build
helmfile --file bootstrap/helmfile.yaml write-values \
  --output-file-template '/tmp/bootstrap-values/{{ .Release.Name }}.yaml'
```
