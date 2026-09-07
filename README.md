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
└── presentation/              # Slide deck (PDF)
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

## Quick Start

```bash
# Explore the singlidation structure
find singlidation/ -name "Chart.yaml" | sort

# Review the ApplicationSet template
cat charts/app-of-appsets/templates/applicationset.yaml

# Check the custom generator
cat custom-applicationset-generator/generator.py
```

## Talk Resources

- [Presentation (PPTX)](./presentation/AWS-Summit-2026.pptx)

## License

MIT
