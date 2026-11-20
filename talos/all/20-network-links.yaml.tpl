---
apiVersion: v1alpha1
kind: LinkConfig
name: enp1s0f0
mtu: 1500
addresses:
  - address: "{{ .Node.IP }}/24"
routes:
  - gateway: "192.168.1.2"
