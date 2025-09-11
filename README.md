# Home Server Kubernetes Platform

GitOps-managed Talos + Flux + Cilium cluster powering self‑hosted services (media, certificates, ingress, experimentation) on modest recycled hardware.

</div>

---

## 1. Overview

This repository is the single source of truth for a Talos-based Kubernetes cluster. Provisioning of the underlying infrastructure is handled by Terraform. The operating system layer (Talos) is bootstrapped once, and everything else (networking, storage, ingress, certificates, applications) reconciles via Flux from this Git repo.

### Core Principles
* Immutable & declarative: No drift; all changes go through Git.
* Minimal pets: Talos OS nodes + a separate NFS box for large RWX media storage.
* Layered concerns: Infra → OS bootstrap → Cluster add‑ons → Applications.
* Reproducibility: Rebuild from scratch with only secrets + this repo + backups.

### High-Level Stack
```
┌────────────────────────────────────────────────────────┐
│                    Users / Clients                     │
└──────────────▲──────────────────────────▲──────────────┘
         │                          │
     Ingress (NGINX)             (Future: Gateway API)
         │
     Cert-Manager + ACME (Let's Encrypt wildcard)
         │
     Cilium CNI  + (MetalLB | Cilium LB IPAM)  
         │
    RWX Storage (NFS CSI)  |  Cluster Services (Secrets, etc)
         │
        Talos Kubernetes Control / Worker Nodes
         │
        Bare Metal Hardware + NFS Host + UPS
```

---

## 2. Hardware Inventory

| Role | Hardware | CPU | RAM | Storage | Notes |
|------|----------|-----|-----|---------|-------|
| k8s node 1 | HP EliteDesk G2 | i7-6700 | 8 GB | 512 GB HDD | Talos OS |
| k8s node 2 | HP EliteDesk G2 | i7-6700 | 8 GB | 128 GB SSD | Talos OS |
| NFS server | HP 280 G1 MT | i3-4160 | 12 GB | 1 TB SSD | Debian + NFS export |
| Power | Eaton 5E UPS | – | – | – | NUT support (planned integration) |

Constraints: Low RAM footprint favors lightweight base OS (Talos) and careful sizing (e.g. no heavy observability stack yet). RWX via external NFS avoids local disk pressure.

---

## 3. Components & Namespaces

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| flux-system | flux-system | GitOps reconciliation of all manifests |
| cert-manager | cert-manager | ACME certificate issuance |
| letsencrypt-wildcard-cert | cert-manager / dedicated | Wildcard DNS-01 issuers + certs |
| ingress-nginx | ingress-nginx | HTTP(S) ingress controller |
| metallb | metallb-system | Bare-metal LoadBalancer IP allocation (optional vs Cilium LB IPAM) |
| csi-driver-nfs | kube-system / custom | Dynamic RWX provisioning from NFS server |
| secret-replicator | secret-replicator | Propagates selected secrets across namespaces |
| podinfo | podinfo | Demo/test application (health for ingress & platform) |
| newt | newt | (Custom/internal app) |
| jellyfin | media | Media server (uses large RWX PVC) |

Planned / Optional: UPS monitoring (NUT exporter), metrics/observability stack, backups operator.

---

## 4. Provisioning Flow (Day 0 → Day 1)

1. Terraform provisions infrastructure (networking, maybe DNS records, and extracts Talos machine configs via outputs).
2. Talos machines boot with generated machine configs (control plane + workers).
3. `talosctl bootstrap` initializes the Kubernetes control plane (first control node).
4. Flux is installed (manual once) and begins reconciling `bootstrap/` then `cluster/` paths.
5. Add‑ons (Cilium, MetalLB, cert-manager, ingress-nginx, NFS CSI) deploy.
6. Applications (podinfo, jellyfin, newt, etc.) roll out automatically.

Rebuild Strategy: Re-run Terraform → apply Talos configs → bootstrap → install Flux secret (age key) → cluster self-heals.

---

## 5. Terraform Usage

```bash
cd infra
terraform init
terraform plan
terraform apply

# Extract kubeconfig & talosconfig
terraform output -raw kubeconfig > ../kubeconfig
terraform output -raw talosconfig > ../talosconfig
cd ..

chmod 600 kubeconfig talosconfig
export KUBECONFIG="$PWD/kubeconfig"
export TALOSCONFIG="$PWD/talosconfig"

# Bootstrap Talos control plane (run once)
talosctl bootstrap --nodes 10.0.0.11
```

---

## 6. Networking (Cilium)

Using Cilium for CNI with kube-proxy replacement and Gateway API CRDs pre-installed (future readiness). Current ingress path uses NGINX IngressController + LoadBalancer IP from MetalLB (or could switch to Cilium LB IPAM by adjusting annotations in the HelmRelease).

Gateway API CRDs installed explicitly (v1.2.0 + experimental TLSRoute). Ingress remains the stable entrypoint until migrating to Gateway API resources.

### 6.1 Install / Update Gateway API CRDs
These must exist **before** enabling Gateway API features in Cilium (you can re-apply safely; they are cluster-scoped CRDs):

```bash
# Standard (stable) Gateway API CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml

# Experimental (optional) TLSRoute support
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
```

Validate:
```bash
kubectl get crd | grep gateway.networking.k8s.io
```

Reference Cilium install parameters (documented for traceability):
```bash
cilium install \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.enableAlpn=true \
  --set gatewayAPI.enableAppProtocol=true
```

Connectivity sanity test:
```bash
kubectl create ns cilium-test-1 \
  && kubectl label ns cilium-test-1 \
     pod-security.kubernetes.io/enforce=privileged \
     pod-security.kubernetes.io/warn=privileged \
     pod-security.kubernetes.io/audit=privileged --overwrite

cilium connectivity test
```

---

## 7. Ingress & TLS

* Ingress Controller: `ingress-nginx` (HelmRelease) with LoadBalancer service.
* Wildcard Certificates: Issued via cert-manager + ACME DNS-01 (Cloudflare token secret encrypted with SOPS).
* Option to pivot to Gateway API for future HTTP routing sophistication.

---

## 8. Storage

* RWX: Provided by external Debian NFS server exposed through the NFS CSI Driver (`csi-driver-nfs`).
* Media PVC: Large (600Gi) claim used by Jellyfin (subPaths for config/cache/media folders inside a shared tree).
* Potential Optimization: Migrate config/cache to separate smaller PVCs to reduce inode scanning overhead.

---

## 9. Applications Detail

### Jellyfin
* Purpose: Media streaming (movies, TV, etc.).
* Deployment: Single replica (SQLite + metadata not safe for multi-writer). Scaling horizontally would require per-replica isolated config and is discouraged.
* Paths: `/config`, `/cache`, `/media` with subPath strategy on a shared PVC.
* Consider adding scheduled rsync/backup of `/config` to a secondary location.

### Podinfo
* Demo/test service validating ingress, DNS, certs, and general platform health.

### Newt
* Placeholder / internal application (details omitted here; expand as needed).

### Secret Replicator
* Automates propagating selected secrets between namespaces (reduces manual duplication for cross-namespace consumers).

### Cert-Manager & ACME Issuers
* Staging + Production issuers defined; wildcard cert reconciled automatically. Rotate Cloudflare token via SOPS if compromised.

---

## 10. Secrets Management (SOPS + age)

1. Age key stored locally as `age.key` (DO NOT COMMIT private key anywhere else).
2. Flux decrypts sealed manifests at reconciliation via `sops-age` secret.
3. Generate a new age key pair (only if you do NOT already have one):
```bash
age-keygen -o age.key
```
4. To (re)create the secret in `flux-system`:
```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=./age.key
```
The public key line (starting with `# public key: age1...`) inside `age.key` is what you embed in your `.sops.yaml` or tooling; keep the file itself private.

### Encrypt Required Secrets
Plaintext versions should NOT be committed. Run encryption locally, then commit only the encrypted output:
```bash
# Cloudflare API token secret (wildcard cert DNS-01)
sops --encrypt --in-place cluster/letsencrypt-wildcard-cert/cloudflare-api-token-service.yaml

# Newt application secret
sops --encrypt --in-place cluster/newt/newt-secret.yaml
```
(Adjust if you prefer in-place `sops -e -i` editing; above pattern keeps originals until you confirm.)
4. Encrypt a file (example):
```bash
sops --encrypt --in-place cluster/letsencrypt-wildcard-cert/cloudflare-api-token-service.yaml
```
(Ensure only encrypted form is committed.)

Rotation: Generate new age key → add new secret → re-encrypt affected files → remove old key after successful deploy.

---

## 11. Operational Cheat Sheet

| Action | Command |
|--------|---------|
| Force reconcile all | `flux reconcile kustomization --all` |
| Get Helm releases | `flux get helmreleases -A` |
| Tail controller logs | `kubectl -n flux-system logs deploy/helm-controller -f` |
| Inspect ingress controller | `kubectl -n ingress-nginx get pods` |
| Describe cert | `kubectl -n cert-manager describe certificate <name>` |
| Check PVC usage (approx) | `kubectl -n media exec deploy/jellyfin -- df -h /media` |

### Recovering After Node Rebuild
1. Re-provision infra (Terraform outputs).
2. Bootstrap Talos control plane.
3. Recreate `sops-age` secret.
4. Wait for Flux to reconcile add‑ons.
5. Validate ingress + certs + storage.

---

## 12. Reliability & Next Steps

| Area | Current | Potential Improvement |
|------|---------|-----------------------|
| Certificates | Automated via cert-manager | Add monitoring for renewal failures |
| Ingress | NGINX LB | Evaluate Gateway API or Cilium Ingress |
| Storage | Single NFS server | Add backups + snapshot (zfs/btrfs) |
| Backups | Manual / TBD | Automate rsync/restic for Jellyfin config |
| Observability | Minimal | Add metrics stack (Prometheus + Grafana) |
| Power | UPS (no integration) | Expose NUT exporter + graceful shutdown |
| Security | SOPS + namespace isolation | Add image scanning / network policies |

---

## 13. Warnings & Caveats
* Do not scale Jellyfin with a shared writable `/config`.
* NFS latency will impact metadata scans; keep library rescans scheduled off-peak.
* Store age key + Cloudflare token securely (password manager + offline backup).
* kubeProxyReplacement=true requires monitoring for unsupported corner cases with some CNIs / features.

---

## 14. Glossary
| Term | Definition |
|------|------------|
| Talos | Minimal, API-driven Linux OS for Kubernetes nodes. |
| Flux | GitOps controller suite applying manifests from Git. |
| MetalLB | Allocates external IPs on bare-metal networks. |
| ACME | Protocol used by Let's Encrypt to issue certificates. |
| RWX | ReadWriteMany access mode for shared volumes. |

---

## 15. License

See `LICENSE` file.

---

## 16. Quick Start (Condensed)
```bash
# Infra
cd infra && terraform init && terraform apply
terraform output -raw kubeconfig > ../kubeconfig
terraform output -raw talosconfig > ../talosconfig && cd ..
chmod 600 kubeconfig talosconfig
export KUBECONFIG=$PWD/kubeconfig TALOSCONFIG=$PWD/talosconfig
talosctl bootstrap --nodes 10.0.0.11

# Secrets
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=./age.key

# Validate
flux get kustomizations
kubectl get pods -A
```

---

Feel free to extend this with backup procedures, diagrams, or monitoring stack details as the platform evolves.