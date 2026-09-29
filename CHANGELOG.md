# Changelog

All notable changes to this project are documented here.

## [1.1.0] — 2026-09-28 — Fixes from the first build on real hardware

The first full build on a Windows 11 Pro host with a USB SSD reached **47/48 checks passing**. That run surfaced the issues below; all are fixed.

| Script | Symptom | What was missing | Fix |
| --- | --- | --- | --- |
| `00-Preflight.ps1` | `FAIL Addressing: outside 192.168.50.1/24` although the lab LAN was `192.168.8.0/24` | Read the LAN from Windows' *preferred* default route, which belonged to a second adapter | Reads the switch's own adapter `vEthernet (<SwitchName>)`, as provisioning does; a second default route is now a `WARN` |
| `scripts/node-prep.sh` | `ERROR: CRI-O CRI endpoint not responding`, although CRI-O was running | **`cri-tools` (`crictl`) was never installed**: kubeadm ≥ 1.36.1 no longer depends on it | Installs and holds `cri-tools` explicitly; checks the socket first, then `crictl info`, with precise errors |
| `scripts/node-prep.sh` | Short image names (for example `nginx`) would be rejected | CRI-O's own `short_name_mode` defaults to `enforcing` and overrides `registries.conf` | Adds `short_name_mode = "disabled"` (CRI-O accepts only `enforcing` or `disabled`) |
| `scripts/platform-install.sh` | `istioctl: command not found` for non-root users; `cilium`/`hubble` owned by uid `1001` | Root's `tar` preserves archive owners and modes; the Istio tree ships as `0750` | Extracts with `--no-same-owner --no-same-permissions`, installs CLIs as `root:root 0755`, and normalises `/opt/istio-*` on every run (repairs existing installs) |
| `scripts/verify-cluster.sh` | `FAIL ztunnel protocol for httpbin: ''` | Root cause was the `istioctl` permission issue above; the check also relied on fixed columns | Matches the row and the `HBONE` token independent of layout, falls back to JSON, and reports an unusable `istioctl` clearly |

**Repair an existing cluster in place:** update the scripts, then run the following on the control plane and re-run `.\02-Bootstrap-Cluster.ps1 -UpdateHostsFile`:

```bash
sudo chown -R root:root /opt/istio-1.31.1 /usr/local/bin/cilium /usr/local/bin/hubble
sudo chmod -R a+rX /opt/istio-1.31.1
```

## [1.0.0] — 2026-09-25 — Initial release

- Hyper-V provisioning of 3 Ubuntu 26.04 VMs (Gen2, Secure Boot, cloud-init NoCloud, static MAC/IP) with storage on a configurable drive.
- kubeadm cluster on CRI-O without kube-proxy.
- Cilium 1.20 (eBPF KPR, native routing, Gateway API, Hubble), MetalLB L2 and Istio 1.31 ambient + sidecar.
- 48-check verification, pre-flight checker, and lab manager with cluster-consistent checkpoints.
