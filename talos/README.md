# Talos configuration

Machine configs are assembled by [topf](https://postfinance.github.io/topf/) from
`topf.yaml` plus the strategic merge patches in this directory.

<https://www.talos.dev/latest/talos-guides/configuration/patching/>

## Layout

- `topf.yaml`: cluster identity, versions, schematic, node list
- `secrets.sops.yaml`: Talos secrets bundle (SOPS-encrypted; `secretsPath` in `topf.yaml`)
- `talosconfig` (gitignored): generated with `task talos:talosconfig`
- `rendered/` (gitignored): output of `task talos:render`

## Patch Directories

Patches merge in this order, alphabetically within each directory, with later
patches taking precedence:

- `all/`: applied to every node
- `control-plane/`: applied to control-plane nodes
- `worker/`: applied to worker nodes
- `node/${hostname}/`: applied to the node with the specified name

Files ending in `.yaml.tpl` are Go-templated per node; see the
[topf configuration model](https://postfinance.github.io/topf/main/configuration-model/)
for the available template variables.

## Workflow

```sh
task talos:talosconfig     # (re)generate talos/talosconfig
task talos:render          # render configs to talos/rendered/
task talos:diff            # topf apply --dry-run (exit 2 = pending changes)
task talos:apply-node NODE=tinykube01 [MODE=auto]
task talos:upgrade-node NODE=tinykube01
task talos:upgrade-k8s
```
