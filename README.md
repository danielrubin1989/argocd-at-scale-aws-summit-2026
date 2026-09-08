# Zero-Risk Infrastructure with ArgoCD at Scale

> **AWS Summit 2026** — Custom Generators, Singlidation, and Gradual Deployment

## Overview

This repository is a companion to the AWS Summit 2026 talk on managing ArgoCD infrastructure across 50+ Kubernetes clusters. It demonstrates three key patterns:

1. **Singlidation** — A single directory tree that serves as the source of truth for all cluster configurations
2. **App-of-ApplicationSets** — A Helm chart that bootstraps ApplicationSets with matrix generators for auto-discovery
3. **Custom ApplicationSet Generator** — A plugin that enables deploy-then-merge workflows for safe infrastructure changes

## Repository Structure

```
├── singlidation/              # Example singlidation repo layout
│   ├── devops/                # Namespace: devops
│   │   ├── external-dns/      #   2 apps per namespace
│   │   └── cert-manager/
│   ├── kube-system/           # Namespace: kube-system
│   │   ├── aws-ebs-csi-driver/
│   │   └── aws-vpc-cni/
│   └── kyverno/               # Namespace: kyverno
│       ├── kyverno/
│       └── kyverno-policy-reporter/
│
├── charts/
│   └── app-of-appsets/        # Helm chart: ApplicationSet with matrix generator
│
├── custom-applicationset-generator/
│   └── generator.py           # Plugin: deploy-then-merge branch overrides
│
├── demo/
│   └── demo.sh                # Runnable end-to-end demo (kind + ArgoCD + Gitea)
│
└── presentation/              # Slide deck (PPTX)
```

## How It Works

### Singlidation Pattern

Each namespace directory contains service subdirectories. Each service has:
- `Chart.yaml` — Helm chart metadata and dependency
- `values-global.yaml` — Default values shared across all clusters
- `values-{cluster}.yaml` — Cluster-specific overrides

When a new cluster is added, just create `values-{cluster}.yaml` files. The ApplicationSet auto-discovers and deploys everything.

### App-of-ApplicationSets

The Helm chart in `charts/app-of-appsets/` creates one ApplicationSet per namespace. Each ApplicationSet uses a **matrix generator** combining:
- **Git files generator** — discovers services by scanning for `values-{cluster}.yaml`
- **Custom plugin generator** — provides branch overrides for gradual deployments

### Custom ApplicationSet Generator (Deploy-Merge Pattern)

Instead of merge-then-deploy (risky), we deploy-then-merge:

1. Open a PR with infrastructure changes
2. CI pipeline sets GitHub commit statuses per deployment phase
3. The custom generator reads these statuses and returns branch overrides
4. Only affected services on target clusters get the PR branch — everything else stays on `main`
5. After validation, merge the PR. Generator returns empty map, services return to `main`.

See [`custom-applicationset-generator/`](./custom-applicationset-generator/) for the plugin implementation.

## Live Demo

[`demo/demo.sh`](./demo/demo.sh) stands the whole thing up on a throwaway [kind](https://kind.sigs.k8s.io/) cluster and proves the payoff live. It is a single self-contained script — every manifest is an inline heredoc, there is nothing else to apply.

**What it proves:** the *same* ApplicationSet, before and after being pointed at the custom generator. Before, all six services follow `main`. After, `external-dns` alone moves to an **unmerged** PR branch while the other five never budge.

### Prerequisites

`docker`, `kind`, `kubectl`, `helm`, `git`, `jq`, `yq` ([mikefarah/yq](https://github.com/mikefarah/yq), not the Python one), `rsync`.

Internet access is required — `argocd-repo-server` fetches the upstream chart dependencies (external-dns, cert-manager, kyverno) live. First run pulls the kind node, ArgoCD, Gitea and Python images: budget a few minutes. Rehearse once so everything is in your local Docker cache.

### Run it

```bash
./demo/demo.sh                    # interactive: Enter to advance between beats (default)
DEMO_SLEEP=0 ./demo/demo.sh       # unattended, no pauses (CI / rehearsal)
DEMO_SLEEP=5 ./demo/demo.sh       # auto-advance every 5 seconds
./demo/demo.sh --keep             # leave the cluster up at the end
./demo/demo.sh --cleanup          # tear down leftovers from a previous run
```

Each beat ends with a bold summary box stating what just happened and which line of output proves it, then waits for Enter.

### The eight beats

| # | Beat | What it does |
|---|------|--------------|
| 0 | Preflight | Verifies every CLI is present and Docker is reachable; prints versions |
| 1 | kind cluster | Creates a single-node cluster with its own kubeconfig under `/tmp` |
| 2 | ArgoCD | Installs pinned ArgoCD **v3.5.2**; waits for repo-server and the ApplicationSet controller |
| 3 | Gitea + "PR #42" | Runs a git server *inside* the cluster, pushes this repo to it, then creates the unmerged branch `feature/upgrade-external-dns` bumping external-dns `replicaCount: 2 → 5` |
| 4 | Appset, no plugin | Installs `charts/app-of-appsets` with the **git generator only**. Six Applications appear, auto-discovered from six values files — all on `main` |
| 5 | Generator up | Builds and deploys `custom-applicationset-generator` in-cluster, then curls it: it answers `external-dns → feature/upgrade-external-dns` and says nothing about the rest |
| 6 | Point the appset at it | One Helm value changes `generators: git` into `generators: matrix(git, plugin)`. No Application is edited, ArgoCD is not restarted |
| 7 | **The payoff** | Polls until `external-dns` flips, prints the table, then confirms `status.sync.revision` equals the PR branch commit — proving the *running* config is the unmerged code |
| 8 | Cleanup | Deletes the cluster and `/tmp/argocd-at-scale-demo` (skipped with `--keep`) |

### What you see

Beat 4 — six Applications generated from six values files, every one following `main`:

```
APP                                  TARGET_REVISION   PATH                                           SYNC
aws-ebs-csi-driver-c1-cluster        main              singlidation/kube-system/aws-ebs-csi-driver    Synced
aws-vpc-cni-c1-cluster               main              singlidation/kube-system/aws-vpc-cni           OutOfSync
cert-manager-c1-cluster              main              singlidation/devops/cert-manager               Synced
external-dns-c1-cluster              main              singlidation/devops/external-dns               Synced
kyverno-c1-cluster                   main              singlidation/kyverno/kyverno                   OutOfSync
kyverno-policy-reporter-c1-cluster   main              singlidation/kyverno/kyverno-policy-reporter   Synced
```

Beat 7 — one service moved, five did not:

```
APP                                  TARGET_REVISION                PATH                                           SYNC
aws-ebs-csi-driver-c1-cluster        main                           singlidation/kube-system/aws-ebs-csi-driver    Synced
aws-vpc-cni-c1-cluster               main                           singlidation/kube-system/aws-vpc-cni           OutOfSync
cert-manager-c1-cluster              main                           singlidation/devops/cert-manager               Synced
external-dns-c1-cluster              feature/upgrade-external-dns   singlidation/devops/external-dns               Synced
kyverno-c1-cluster                   main                           singlidation/kyverno/kyverno                   OutOfSync
kyverno-policy-reporter-c1-cluster   main                           singlidation/kyverno/kyverno-policy-reporter   Synced
```

```
+======================================================================+
| THE PAYOFF - ONE SERVICE MOVED, FIVE DID NOT                         |
|                                                                      |
|   external-dns  ->  feature/upgrade-external-dns   (unmerged PR)     |
|   the other 5   ->  main                          (never moved)      |
|                                                                      |
| Same ApplicationSet. Same repo. No Application was hand-edited.      |
| A generator decided, per service, which git ref to follow.           |
|                                                                      |
| CONFIRMED: sync.revision == the PR commit, so the code that is       |
| actually running is the unmerged PR - not main.                      |
|                                                                      |
| THIS IS DEPLOY-THEN-MERGE: prove a risky infra change on real        |
| clusters, one service at a time, BEFORE it lands on main. If it      |
| misbehaves, close the PR - nothing was ever merged to roll back.     |
+======================================================================+
```

### Safety

The script is built to be safe to run on a work machine that has production cluster contexts configured:

- `KUBECONFIG` is pointed at `/tmp/argocd-at-scale-demo/kubeconfig` for the whole run. Your `~/.kube/config` is never read or written, and your current context is left alone.
- Every `kubectl`/`helm` call also passes `--context kind-argocd-at-scale` explicitly.
- This repo is never checked out, branched or committed to. Its contents are copied to `/tmp` with `rsync` and the demo branch is created there.
- Nothing is pushed to GitHub. The "PR" exists only in the ephemeral in-cluster Gitea, so the `repoURL` in the tables is a Gitea service URL rather than a GitHub one.
- On unexpected failure the script prints the cleanup command and leaves the cluster intact for inspection rather than destroying evidence.

### Expected noise

Applications show `OutOfSync`, `Missing` or `ComparisonError` because the singlidation charts reference real upstream Helm repositories and nothing pre-populates them in a throwaway cluster. That is expected and irrelevant to what the demo proves — the `targetRevision` field, i.e. *which git ref* ArgoCD uses per service. The script says so up front so it does not read as breakage.

## Talk Resources

- [Presentation (PPTX)](./presentation/AWS-Summit-2026.pptx)

## License

MIT
