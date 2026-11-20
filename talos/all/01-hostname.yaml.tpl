# auto: "off" overrides the generator's default `auto: stable` (conflicts with `hostname`).
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: "{{ .Node.Host }}"
