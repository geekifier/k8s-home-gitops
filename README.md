# xenu-ng

Xenu Next Generation Home Platform

Based on the excellent work by @onedr0p in [home-ops](https://github.com/onedr0p/home-ops) and [cluster-template](https://github.com/onedr0p/cluster-template) community.

## Implemented Features

### Workspace integration with MCP

With the release of [Flux Operator MCP Server](https://fluxcd.io/blog/2025/05/ai-assisted-gitops/), I was able to integrate my gitops workspace with Github Copilot. With the use of [custom instructions](.github/copilot-instructions.md) Copilot is able to use the tools provided by the MCP (and this repo) to interact with the cluster.

This functionality is still in development, but it has been a real game changer in terms of LLM usefulness for cluster management

For example, I can ask the Agent to investigate running pods and propose improvements to their running configs, such as health probes.

You can see the custom instructions [here](.github/copilot-instructions.md) (work in progress).

### Using Cilium ingress instead of nginx-ingress

I decided to keep using `ingress-nginx` until Gateway API matures.

I had a great experience with Traefik in my non-k8s environment, so that's another option as well.

## ⚙️ Software Components

-   [Talos Linux](https://github.com/siderolabs/talos) - API-driven, Kubernetes-focused Linux distribution
-   [Flux](https://github.com/fluxcd/flux2) - continuous delivery via a GitOps model
-   [SOPS](https://github.com/getsops/sops) combined with [age](https://github.com/FiloSottile/age) - secrets management
-   [cloudflared](https://github.com/cloudflare/cloudflared) - provision Cloudflare Tunnels for publicly exposed endpoints
-   [external-dns](https://github.com/kubernetes-sigs/external-dns) - on-demand DNS record provisioning inside Samba (Active Directory) DNS with Kerberos auth
-   [Longhorn](https://longhorn.io/) - cloud-native distributed block storage for Kubernetes
-   [CloudNativePG](https://cloudnative-pg.io/) - deploy HA PostgreSQL clusters on K8s with ease
-   [postgres-operator](https://github.com/movetokube/postgres-operator) - operator to manage DBs and roles

## Hardware

### Compute

| Name       | Model                  | CPU                  | RAM             | Storage                          |
| ---------- | ---------------------- | -------------------- | --------------- | -------------------------------- |
| tinynode01 | ThinkCentre M920q Tiny | i5-8600T (6c/6t/9MB) | 32 GB DDR4 3200 | Samsung 980 Pro 2TB NVMe         |
| tinynode02 | ThinkCentre M920q Tiny | i5-8600T (6c/6t/9MB) | 32 GB DDR4 3200 | Inland Performance Plus 1TB NVMe |
| tinynode03 | ThinkCentre M920q Tiny | i5-8600T (6c/6t/9MB) | 32 GB DDR4 3200 | Solidigm SSDPFKKW010X7 1TB NVMe  |

#### Estimated Costs

The 3 M920q nodes were purchased from eBay for around $300. Similar models can routinely be found (as of March 2025) for a similar price.
Some of the other parts, like SSDs and some of the RAM, were scavenged from my inventory. Nevertheless, I am listing the BOM with estimated costs for planning purposes.

| Item            | Model                               | Unit Cost | Source                        | Comments                                                                |
| --------------- | ----------------------------------- | :-------: | ----------------------------- | ----------------------------------------------------------------------- |
| Compute Node    | ThinkCentre M920q Tiny              |   $100    | eBay                          | Excellent condition                                                     |
| 32 GB DDR4 RAM  | Crucial CT2K16G4SFRA32A             |    $45    | Best Buy (Sale)               | Already had one kit                                                     |
| 1 TB NVME       | Inland Performance Plus 1TB NVMe    |  $69.99   | MicroCenter                   | 700TBW endurance                                                        |
| 10 GbE NIC      | SuperMicro AOC-STGN-I2S Low Profile |   ~$18    | eBay                          | 3D printed a [custom baffle](https://www.thingiverse.com/thing:6348691) |
| 1.5M DAC Cables | SFP-H10GB-CU1.5M Cisco Compatible   |    $11    | eBay (Private Label Networks) |

# Changelog

## 2025-05

### Talos migration to bare metal!

With the release of [Talos v1.10](https://www.talos.dev/v1.10/introduction/what-is-new/), and its support for [User Volumes](https://www.talos.dev/v1.10/talos-guides/configuration/disk-management/#user-volumes), I was able to eliminate the use of Proxmox and switches all my k8s nodes over to bare metal.

### LLM MCP integration for Flux

Added a section in the README describing the new AI integration.

# External Resources

## Hardware

-   [STH Forum: Lenovo Project TinyMiniMicro Reference Thread](https://forums.servethehome.com/index.php?threads/lenovo-thinkcentre-thinkstation-tiny-project-tinyminimicro-reference-thread.34925/)
-   [github.com/a-little-wifi/Tinyriser](https://github.com/a-little-wifi/Tinyriser) open-source PCIe riser for Lenovo 8/9th gen Tiny PCs
