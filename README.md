# xenu-ng

Xenu Next Generation Home Platform

Based on the excellent work by @onedr0p in [home-ops](https://github.com/onedr0p/home-ops) and [cluster-template](https://github.com/onedr0p/cluster-template) community.

## Changes from the original

### Deployment into Proxmox VMs vs bare metal

Originally, I wanted to deploy the cluster onto my bare metal k8s nodes, but due to [limitations](https://github.com/siderolabs/talos/issues/8367) in Talos Linux related to volume management, I decided to run Talos in VMs.

Once Talos matures and allows for better volume management, I may revisit this. Target: Talos v1.10.

### Configuring Proxmox

I used my existing Ansible setup in another repo to provision a new Proxmox cluster across the 3 cluster nodes.

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

# External Resources

## Hardware

-   [STH Forum: Lenovo Project TinyMiniMicro Reference Thread](https://forums.servethehome.com/index.php?threads/lenovo-thinkcentre-thinkstation-tiny-project-tinyminimicro-reference-thread.34925/)
-   [github.com/a-little-wifi/Tinyriser](https://github.com/a-little-wifi/Tinyriser) open-source PCIe riser for Lenovo 8/9th gen Tiny PCs
