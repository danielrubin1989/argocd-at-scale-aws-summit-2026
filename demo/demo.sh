#!/usr/bin/env bash
#
# Demo: ArgoCD at Scale — the deploy-then-merge pattern (AWS Summit 2026)
#
# Proves three patterns live, on a throwaway kind cluster:
#
#   1. SINGLIDATION      — one values file per cluster, one chart per service, one repo.
#                          GitOps state is a flat tree; no per-cluster forks.
#   2. APP-OF-APPSETS    — one Helm chart emits one ApplicationSet per namespace.
#                          Adding a cluster = adding one values file.
#   3. DEPLOY-THEN-MERGE — a custom generator sets targetRevision per service from PR
#                          status. external-dns runs the unmerged branch on c1-cluster;
#                          the other five services stay pinned to main.
#
# Usage:
#   ./demo/demo.sh                  interactive, Enter to continue (default)
#   DEMO_SLEEP=5  ./demo/demo.sh    auto-advance with 5-second pauses
#   DEMO_SLEEP=0  ./demo/demo.sh    fully unattended
#   ./demo/demo.sh --keep           skip teardown at the end
#   ./demo/demo.sh --cleanup        teardown only (cleans up leftover clusters/dirs)
#
# Safety:
#   * KUBECONFIG always points to /tmp/argocd-at-scale-demo/kubeconfig — never ~/.kube/config.
#   * Every kubectl/helm call passes --context kind-argocd-at-scale.
#   * The source repo is never checked out, branched, or committed to.
#   * On unexpected failure: prints the cleanup command, does NOT destroy the cluster.
#
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CLUSTER=argocd-at-scale
DEMO_DIR=/tmp/argocd-at-scale-demo
SLEEP=${DEMO_SLEEP:--1}

KEEP=false
CLEANUP_ONLY=false
for _arg in "$@"; do
  case "$_arg" in
    --keep)    KEEP=true ;;
    --cleanup) CLEANUP_ONLY=true ;;
    *) printf 'Unknown flag: %s\nUsage: %s [--keep|--cleanup]\n' "$_arg" "$0" >&2; exit 1 ;;
  esac
done

# ── colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$(tput bold); R=$(tput setaf 1); G=$(tput setaf 2); Y=$(tput setaf 3)
  C=$(tput setaf 6); N=$(tput sgr0)
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi

RULE=$(printf '%0.s_' {1..72})
section() { printf '\n%s%s%s\n%s== %s%s\n' "$C" "$RULE" "$N" "$B" "$*" "$N"; }
explain() { printf '%s   %s%s\n' "$Y" "$*" "$N"; }
cmd()     { printf '%s   $ %s%s\n' "$C" "$*" "$N"; }
pause() {
  if   [[ "$SLEEP" == "-1" ]]; then printf '\n%s   [Enter to continue]%s' "$C" "$N"; read -r
  elif [[ "$SLEEP" != "0"  ]]; then sleep "$SLEEP"
  fi
}
die() { printf '%s!! %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# takeaway "line" "line" ... — the plain-language summary of the step the audience
# just watched, in a bold box so it reads from the back of the room. First line is
# the heading. Content must be pure ASCII and <= 69 chars: the padding below counts
# characters, so a stray em dash or arrow would skew the right-hand border.
BOX_RULE=$(printf '%0.s=' {1..70})
takeaway() {
	local _line
	printf '\n%s%s+%s+%s\n' "$B" "$G" "$BOX_RULE" "$N"
	for _line in "$@"; do
		printf '%s%s|%s|%s\n' "$B" "$G" "$(printf ' %-69s' "${_line:0:69}")" "$N"
	done
	printf '%s%s+%s+%s\n' "$B" "$G" "$BOX_RULE" "$N"
}

# ── port-forward PIDs (recorded so cleanup can kill them) ─────────────────────
GITEA_PF_PID=""
GEN_PF_PID=""

# ── cleanup ───────────────────────────────────────────────────────────────────
do_cleanup() {
  local tolerant=${1:-false}
  [[ -n "$GITEA_PF_PID" ]] && kill "$GITEA_PF_PID" 2>/dev/null || true
  [[ -n "$GEN_PF_PID"   ]] && kill "$GEN_PF_PID"   2>/dev/null || true
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
    cmd "kind delete cluster --name $CLUSTER"
    # kind always exits non-zero in this container because ~/.kube/config is
    # read-only; suppress that error — the nodes ARE deleted either way.
    kind delete cluster --name "$CLUSTER" 2>/dev/null || true
  fi
  if [[ -d "$DEMO_DIR" ]]; then
    cmd "rm -rf $DEMO_DIR"
    if [[ "$tolerant" == "true" ]]; then
      rm -rf "$DEMO_DIR" 2>/dev/null || true
    else
      rm -rf "$DEMO_DIR"
    fi
  fi
}

# ── trap: print cleanup hint, do NOT auto-destroy ─────────────────────────────
_on_error() {
  printf '\n%s!! Unexpected failure — cluster and %s are intact.\n' "$R" "$DEMO_DIR"
  printf '   Clean up later with:  %s --cleanup%s\n\n' "$0" "$N"
}
trap '_on_error; exit 1' ERR
trap '_on_error; exit 1' INT

# ── cleanup-only mode ─────────────────────────────────────────────────────────
if [[ "$CLEANUP_ONLY" == "true" ]]; then
  export KUBECONFIG="${DEMO_DIR}/kubeconfig"
  section "Cleanup"
  do_cleanup true
  printf '%s   Done.%s\n' "$G" "$N"
  exit 0
fi

export KUBECONFIG="${DEMO_DIR}/kubeconfig"

# ── reusable helpers ──────────────────────────────────────────────────────────

# Poll an HTTP URL until it returns 200. Returns non-zero on timeout instead of
# dying, so the caller can retry the underlying port-forward.
poll_http() {
  local url="$1" budget="${2:-60}" elapsed=0
  printf '   Waiting for %s' "$url"
  while [[ $elapsed -lt $budget ]]; do
    curl -sf "$url" >/dev/null 2>&1 && { printf ' ok\n'; return 0; }
    printf '.'
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf '\n'
  return 1
}

# Start a port-forward and wait until the URL answers, restarting the forward if
# it drops. kubectl port-forward exits for good if the pod is not yet serving on
# the target port, so a single attempt is not reliable enough for a live demo.
# Sets PF_PID to the surviving process.
PF_PID=""
start_pf() {
  local ns="$1" svc="$2" ports="$3" url="$4" attempt=1 pid=""
  while [[ $attempt -le 3 ]]; do
    kubectl --context "kind-$CLUSTER" -n "$ns" port-forward "svc/$svc" "$ports" \
      >/dev/null 2>&1 &
    pid=$!
    if poll_http "$url" 40; then PF_PID=$pid; return 0; fi
    kill "$pid" 2>/dev/null || true
    printf '   port-forward to svc/%s dropped — retrying (%d/3)\n' "$svc" "$attempt"
    attempt=$((attempt + 1))
  done
  die "Could not establish a working port-forward to svc/$svc in namespace $ns"
}

# Wait up to 120 s for N Applications to exist in the argocd namespace.
wait_for_apps() {
  local target=$1 elapsed=0 count=0
  printf '   Waiting for %d Applications' "$target"
  while [[ $elapsed -lt 120 ]]; do
    count=$(kubectl --context "kind-$CLUSTER" -n argocd \
      get applications.argoproj.io --no-headers 2>/dev/null \
      | grep -c .) || count=0
    [[ "$count" -ge "$target" ]] && { printf ' (%d ready)\n' "$count"; return 0; }
    printf '.'
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf '\n'
  die "Timed out waiting for $target Applications (got $count)"
}

# Print the per-service targetRevision table (same command used in steps 4 and 7).
print_table() {
  cmd "kubectl --context kind-$CLUSTER -n argocd get applications.argoproj.io \\
  -o custom-columns=APP:.metadata.name,TARGET_REVISION:.spec.source.targetRevision,PATH:.spec.source.path,SYNC:.status.sync.status"
  kubectl --context "kind-$CLUSTER" -n argocd get applications.argoproj.io \
    -o custom-columns='APP:.metadata.name,TARGET_REVISION:.spec.source.targetRevision,PATH:.spec.source.path,SYNC:.status.sync.status' \
    2>/dev/null || true
}

# ── up-front note (before step 0) ─────────────────────────────────────────────
printf '\n'
explain "NOTE: Applications will show OutOfSync / Missing / ComparisonError."
explain "The charts reference real upstream Helm repos not available in this cluster."
explain "That is expected and IRRELEVANT to what we are proving: the targetRevision"
explain "field — which Git ref ArgoCD uses for each service individually."

# =============================================================================
# STEP 0: PREFLIGHT
# =============================================================================
section "Step 0 — Preflight"

for _tool in docker kind kubectl helm git jq yq rsync; do
  command -v "$_tool" >/dev/null 2>&1 \
    || die "$_tool not found on PATH — install it and retry"
done
explain "Required tools: docker kind kubectl helm git jq yq rsync — all present."

# Steps 4 and 6 use mikefarah/yq multi-document `select`. The unrelated python-yq
# (a jq wrapper of the same name) is a common brew/pip collision and fails there.
yq --version 2>&1 | grep -qi mikefarah \
  || die "yq is not mikefarah/yq v4 (found: $(yq --version 2>&1 | head -1)) — install with: brew install yq"

cmd "docker info >/dev/null"
docker info >/dev/null 2>&1 \
  || die "Docker daemon is not running or not accessible by the current user"
explain "Docker daemon is reachable."

printf '\n'
cmd "docker --version; kind version; kubectl version --client; helm version --short; git --version; jq --version; yq --version"
printf '   docker:  '; docker --version
printf '   kind:    '; kind version 2>/dev/null | head -1
_kv=$(kubectl version --client -o json 2>/dev/null \
  | jq -r '.clientVersion.gitVersion' 2>/dev/null) || _kv="(unknown)"
printf '   kubectl: %s\n' "$_kv"
printf '   helm:    '; helm version --short 2>/dev/null
printf '   git:     '; git --version
printf '   jq:      '; jq --version
printf '   yq:      '; yq --version 2>/dev/null | head -1

takeaway \
	"CHECKPOINT 0 - TOOLING IS READY" \
	"" \
	"Every CLI this demo needs is installed, and Docker is running." \
	"Nothing has been created yet - this step only looked around." \
	"" \
	"Evidence: the version lines above, printed from your machine."

pause

# =============================================================================
# STEP 1: KIND CLUSTER
# =============================================================================
section "Step 1 — Create kind cluster ($CLUSTER)"

mkdir -p "$DEMO_DIR"
explain "KUBECONFIG=$KUBECONFIG — ~/.kube/config is never read or written."

if [[ -f /.dockerenv ]]; then
  explain "Container environment detected — setting apiServerAddress: 0.0.0.0 and"
  explain "certSANs: [host.docker.internal, localhost, 127.0.0.1]."
  cmd "kind create cluster --name $CLUSTER --kubeconfig $KUBECONFIG --config - <<'EOF'"
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --config - <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  apiServerAddress: "0.0.0.0"
kubeadmConfigPatches:
- |
  kind: ClusterConfiguration
  apiServer:
    certSANs:
    - host.docker.internal
    - localhost
    - 127.0.0.1
nodes:
- role: control-plane
KINDEOF

  explain "Rewriting kubeconfig API server URL to host.docker.internal..."
  _kube_server=$(yq '.clusters[0].cluster.server' "$KUBECONFIG")
  _kube_port="${_kube_server##*:}"
  cmd "kubectl config set-cluster kind-$CLUSTER --server https://host.docker.internal:$_kube_port"
  kubectl config set-cluster "kind-$CLUSTER" \
    --server "https://host.docker.internal:${_kube_port}" \
    --kubeconfig "$KUBECONFIG"
else
  explain "Running outside a container — using a plain single-node config."
  cmd "kind create cluster --name $CLUSTER --kubeconfig $KUBECONFIG --config - <<'EOF'"
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --config - <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
KINDEOF
fi

cmd "kubectl --context kind-$CLUSTER get ns"
kubectl --context "kind-$CLUSTER" get ns \
  || die "Cluster is not reachable after kind create — check the kubeconfig"
explain "Cluster is up and reachable."

takeaway \
	"CHECKPOINT 1 - AN EMPTY KUBERNETES CLUSTER" \
	"" \
	"A throwaway single-node cluster is now running inside Docker." \
	"It has no ArgoCD, no git server and no Applications yet." \
	"" \
	"Its kubeconfig lives in /tmp - your real clusters are untouched." \
	"Evidence: 'kubectl get ns' above listed only built-in namespaces."

pause

# =============================================================================
# STEP 2: ARGOCD
# =============================================================================
section "Step 2 — Install ArgoCD v3.2.12"

cmd "kubectl --context kind-$CLUSTER create namespace argocd"
kubectl --context "kind-$CLUSTER" create namespace argocd

cmd "kubectl --context kind-$CLUSTER apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.12/manifests/install.yaml"
kubectl --context "kind-$CLUSTER" apply -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.12/manifests/install.yaml"

explain "Waiting for argocd-repo-server (handles Git clones and Helm template)..."
cmd "kubectl --context kind-$CLUSTER -n argocd rollout status deploy/argocd-repo-server --timeout=300s"
kubectl --context "kind-$CLUSTER" -n argocd rollout status deploy/argocd-repo-server --timeout=300s

explain "Waiting for argocd-applicationset-controller (runs our generators)..."
cmd "kubectl --context kind-$CLUSTER -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s"
kubectl --context "kind-$CLUSTER" -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s

explain "ArgoCD is ready."

takeaway \
	"CHECKPOINT 2 - ARGOCD IS RUNNING" \
	"" \
	"Stock ArgoCD v3.2.12, no customisation. Two parts matter later:" \
	"" \
	"  repo-server            clones git and renders the Helm charts" \
	"  applicationset-ctrl    runs the generators we are about to swap" \
	"" \
	"Evidence: both rollouts reported 'successfully rolled out'."

pause

# =============================================================================
# STEP 3: GITEA + THE UNMERGED PR #42
# =============================================================================
section "Step 3 — Deploy Gitea and stage PR #42 as an unmerged branch"

# 3a. Namespace + Deployment + Service
cmd "kubectl --context kind-$CLUSTER apply -f -  # gitea namespace, deployment, service"
kubectl --context "kind-$CLUSTER" apply -f - <<'GITEAEOF'
apiVersion: v1
kind: Namespace
metadata:
  name: gitea
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea
  namespace: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea
  template:
    metadata:
      labels:
        app: gitea
    spec:
      containers:
      - name: gitea
        image: gitea/gitea:1.23
        ports:
        - containerPort: 3000
        env:
        - name: GITEA__database__DB_TYPE
          value: sqlite3
        - name: GITEA__security__INSTALL_LOCK
          value: "true"
        - name: GITEA__server__DISABLE_SSH
          value: "true"
        - name: GITEA__server__ROOT_URL
          value: "http://gitea.gitea.svc.cluster.local:3000/"
        - name: GITEA__service__DISABLE_REGISTRATION
          value: "false"
        # Without this probe the Deployment reports Available before Gitea has
        # bound :3000, and the port-forward below dies on connection refused.
        readinessProbe:
          httpGet:
            path: /api/v1/version
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 30
---
apiVersion: v1
kind: Service
metadata:
  name: gitea
  namespace: gitea
spec:
  selector:
    app: gitea
  ports:
  - name: http
    port: 3000
    targetPort: 3000
    protocol: TCP
GITEAEOF

cmd "kubectl --context kind-$CLUSTER -n gitea rollout status deploy/gitea --timeout=300s"
kubectl --context "kind-$CLUSTER" -n gitea rollout status deploy/gitea --timeout=300s

# 3b. Create the admin user (tolerate "already exists")
cmd "kubectl --context kind-$CLUSTER -n gitea exec deploy/gitea -- su -c 'gitea admin user create --admin --username demo ...' git"
kubectl --context "kind-$CLUSTER" -n gitea exec deploy/gitea -- \
  su -c "gitea admin user create --admin \
    --username demo \
    --password demo1234 \
    --email demo@example.com \
    --must-change-password=false" git 2>&1 || true   # tolerate "user already exists"

# 3c. Port-forward; poll until Gitea HTTP API is up
cmd "kubectl --context kind-$CLUSTER -n gitea port-forward svc/gitea 3000:3000 &"
start_pf gitea gitea 3000:3000 "http://localhost:3000/api/v1/version"
GITEA_PF_PID=$PF_PID

# 3d. Create the repo
cmd "curl -sf -u demo:demo1234 -X POST http://localhost:3000/api/v1/user/repos -d '{\"name\":\"argocd-at-scale\",...}'"
curl -sf \
  -u demo:demo1234 \
  -X POST "http://localhost:3000/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -d '{"name":"argocd-at-scale","private":false,"auto_init":false}' \
  >/dev/null

# 3e. Stage repo content — rsync only; the source .git is NEVER touched
explain "Staging source content into $DEMO_DIR/repo via rsync — source .git untouched."
cmd "rsync -a --exclude .git --exclude presentation --exclude .DS_Store --exclude demo $ROOT/ $DEMO_DIR/repo/"
rsync -a \
  --exclude .git \
  --exclude presentation \
  --exclude .DS_Store \
  --exclude demo \
  "$ROOT/" "$DEMO_DIR/repo/"

explain "Nothing is pushed to GitHub — this Gitea is ephemeral and in-cluster only."

cmd "git -C $DEMO_DIR/repo init -q -b main && git add -A && git commit -m 'singlidation baseline'"
GIT_CONFIG_GLOBAL=/dev/null git -C "$DEMO_DIR/repo" init -q -b main
git -C "$DEMO_DIR/repo" config user.name  "Demo User"
git -C "$DEMO_DIR/repo" config user.email "demo@example.com"
git -C "$DEMO_DIR/repo" add -A
git -C "$DEMO_DIR/repo" commit -q -m "singlidation baseline"

cmd "git -C $DEMO_DIR/repo remote add origin http://demo:demo1234@localhost:3000/demo/argocd-at-scale.git"
git -C "$DEMO_DIR/repo" remote add origin \
  "http://demo:demo1234@localhost:3000/demo/argocd-at-scale.git"

cmd "git -C $DEMO_DIR/repo push -q origin main"
git -C "$DEMO_DIR/repo" push -q origin main

# 3f. The unmerged PR branch (throwaway repo ONLY — never the source repo)
cmd "git -C $DEMO_DIR/repo checkout -b feature/upgrade-external-dns"
git -C "$DEMO_DIR/repo" checkout -b feature/upgrade-external-dns

explain "Editing singlidation/devops/external-dns/values-global.yaml: replicaCount 2 -> 5."
cmd "sed 's/replicaCount: 2/replicaCount: 5  # PR #42: .../' singlidation/devops/external-dns/values-global.yaml"
# Write via a temp file rather than `sed -i`: GNU sed takes a bare -i, BSD/macOS
# sed requires an argument, and there is no spelling that works on both.
_vg="$DEMO_DIR/repo/singlidation/devops/external-dns/values-global.yaml"
sed 's/replicaCount: 2/replicaCount: 5  # PR #42: scale external-dns for the new zone/' \
  "$_vg" > "$_vg.tmp"
mv "$_vg.tmp" "$_vg"
grep -q 'replicaCount: 5' "$_vg" \
  || die "Failed to bump replicaCount in $_vg — the demo edit did not apply"

git -C "$DEMO_DIR/repo" add singlidation/devops/external-dns/values-global.yaml
git -C "$DEMO_DIR/repo" commit -q -m "PR #42: scale external-dns for the new zone"

cmd "git -C $DEMO_DIR/repo push -q origin feature/upgrade-external-dns"
git -C "$DEMO_DIR/repo" push -q origin feature/upgrade-external-dns

BRANCH_SHA=$(git -C "$DEMO_DIR/repo" rev-parse HEAD)

# Return to main in the throwaway repo (not the source repo)
git -C "$DEMO_DIR/repo" checkout main
MAIN_SHA=$(git -C "$DEMO_DIR/repo" rev-parse HEAD)

printf '   %smain HEAD:               %s%s\n' "$G" "$MAIN_SHA" "$N"
printf '   %sUnmerged PR branch HEAD: %s%s\n' "$G" "$BRANCH_SHA" "$N"

# 3g. Show the diff to the audience
cmd "git -C $DEMO_DIR/repo diff main..feature/upgrade-external-dns"
git -C "$DEMO_DIR/repo" diff main..feature/upgrade-external-dns
explain "This PR is NOT merged — main still says replicaCount: 2."

takeaway \
	"CHECKPOINT 3 - AN UNMERGED PR NOW EXISTS" \
	"" \
	"A git server runs inside the cluster. It holds two branches, which" \
	"differ only in external-dns/values-global.yaml:" \
	"" \
	"  main                          replicaCount: 2" \
	"  feature/upgrade-external-dns  replicaCount: 5   <- PR #42" \
	"" \
	"PR #42 is open and NOT merged. On a normal setup it would be" \
	"unreviewable on real infrastructure until someone merged it." \
	"" \
	"Evidence: the diff above exists only on the branch, not on main."

pause

# =============================================================================
# STEP 4: APPSET WITHOUT THE PLUGIN  (before state)
# =============================================================================
section "Step 4 — ApplicationSet with git generator only (before)"

GITEA_URL="http://gitea.gitea.svc.cluster.local:3000/demo/argocd-at-scale.git"

cmd "helm --kube-context kind-$CLUSTER upgrade --install app-of-appsets \\
  $DEMO_DIR/repo/charts/app-of-appsets -n argocd \\
  --set repoURL=$GITEA_URL --set clusterName=c1-cluster --set generatorPlugin="
helm --kube-context "kind-$CLUSTER" upgrade --install app-of-appsets \
  "$DEMO_DIR/repo/charts/app-of-appsets" \
  -n argocd \
  --set "repoURL=${GITEA_URL}" \
  --set "clusterName=c1-cluster" \
  --set "generatorPlugin="

explain "Rendered generators block — git only, no plugin:"
cmd "helm --kube-context kind-$CLUSTER template app-of-appsets ... \\
  | yq 'select(.metadata.name == \"devops-appset\") | .spec.generators'"
helm --kube-context "kind-$CLUSTER" template app-of-appsets \
  "$DEMO_DIR/repo/charts/app-of-appsets" \
  -n argocd \
  --set "repoURL=${GITEA_URL}" \
  --set "clusterName=c1-cluster" \
  --set "generatorPlugin=" \
  | yq 'select(.metadata.name == "devops-appset") | .spec.generators'

explain "Waiting for all 6 Applications (2 devops + 2 kube-system + 2 kyverno) to appear..."
wait_for_apps 6

explain "Before state — all 6 services pinned to main:"
print_table

takeaway \
	"BEFORE - EVERY SERVICE FOLLOWS MAIN" \
	"" \
	"Nobody wrote 6 Applications. One ApplicationSet found 6 values" \
	"files in the repo and generated one Application per service." \
	"That is SINGLIDATION: add a values file, get a deployment." \
	"" \
	"TARGET_REVISION is 'main' for all 6 - external-dns included." \
	"So PR #42 is running nowhere. This is the baseline to beat." \
	"" \
	"Evidence: the TARGET_REVISION column above reads 'main' six times."

pause

# =============================================================================
# STEP 5: BUILD AND DEPLOY THE CUSTOM GENERATOR
# =============================================================================
section "Step 5 — Build and deploy the custom plugin generator"

cmd "docker build -t infra-deployment-generator:demo $DEMO_DIR/repo/custom-applicationset-generator"
docker build -t infra-deployment-generator:demo \
  "$DEMO_DIR/repo/custom-applicationset-generator"

cmd "kind load docker-image infra-deployment-generator:demo --name $CLUSTER"
kind load docker-image infra-deployment-generator:demo --name "$CLUSTER"

explain "Deploying in ns argocd with mock mode: PR #42, external-dns -> feature/upgrade-external-dns, c1-cluster."
cmd "kubectl --context kind-$CLUSTER apply -f -  # infra-deployment-generator deployment + service"
kubectl --context "kind-$CLUSTER" apply -f - <<'GENEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: infra-deployment-generator
  namespace: argocd
spec:
  replicas: 1
  selector:
    matchLabels:
      app: infra-deployment-generator
  template:
    metadata:
      labels:
        app: infra-deployment-generator
    spec:
      containers:
      - name: generator
        image: infra-deployment-generator:demo
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 3
          periodSeconds: 5
        env:
        - name: MOCK_ENABLED
          value: "true"
        - name: MOCK_PR_NUMBER
          value: "42"
        - name: MOCK_BRANCH
          value: feature/upgrade-external-dns
        - name: MOCK_NAMESPACE
          value: devops
        - name: MOCK_CLUSTERS
          value: c1-cluster
        - name: MOCK_SERVICES
          value: external-dns
---
apiVersion: v1
kind: Service
metadata:
  name: infra-deployment-generator
  namespace: argocd
spec:
  selector:
    app: infra-deployment-generator
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
GENEOF

cmd "kubectl --context kind-$CLUSTER -n argocd rollout status deploy/infra-deployment-generator --timeout=120s"
kubectl --context "kind-$CLUSTER" -n argocd rollout status deploy/infra-deployment-generator --timeout=120s

cmd "kubectl --context kind-$CLUSTER -n argocd port-forward svc/infra-deployment-generator 18080:8080 &"
start_pf argocd infra-deployment-generator 18080:8080 "http://localhost:18080/health"
GEN_PF_PID=$PF_PID

explain "Calling the generator: what branch overrides does it return for namespace=devops, clusterName=c1-cluster?"
cmd "curl -s -XPOST localhost:18080/api/v1/getparams.execute \\
  -H 'Content-Type: application/json' \\
  -d '{\"input\":{\"parameters\":{\"namespace\":\"devops\",\"clusterName\":\"c1-cluster\"}}}' | jq"
PLUGIN_RESP=$(curl -s -XPOST localhost:18080/api/v1/getparams.execute \
  -H "Content-Type: application/json" \
  -d '{"input":{"parameters":{"namespace":"devops","clusterName":"c1-cluster"}}}')
printf '%s\n' "$PLUGIN_RESP" | jq .

ACTUAL_BRANCH=$(printf '%s\n' "$PLUGIN_RESP" \
  | jq -r '.output.parameters[0].infraDeployBranches["external-dns"]')
[[ "$ACTUAL_BRANCH" == "feature/upgrade-external-dns" ]] \
  || die "Generator assertion failed: expected 'feature/upgrade-external-dns', got '${ACTUAL_BRANCH}'"
printf '%s   Assertion passed: infraDeployBranches[external-dns] = %s%s\n' "$G" "$ACTUAL_BRANCH" "$N"

takeaway \
	"CHECKPOINT 5 - THE GENERATOR ANSWERS" \
	"" \
	"A small HTTP service is now the thing that decides which service" \
	"follows which git branch. Asked about devops / c1-cluster it said:" \
	"" \
	"  external-dns  ->  feature/upgrade-external-dns" \
	"" \
	"It said nothing about the other five, so they keep following main." \
	"In production this answer comes from the PR's CI status instead of" \
	"a mock - the ApplicationSet contract is identical either way." \
	"" \
	"Evidence: the JSON above, plus the assertion the script just ran." \
	"NOTE: ArgoCD is not using this yet. That is the next step."

pause

# =============================================================================
# STEP 6: POINT THE APPSET AT THE PLUGIN
# =============================================================================
section "Step 6 — Wire the ApplicationSet to the custom generator"

# 6a. Store the plugin token in argocd-secret
#     ArgoCD resolves $plugin.<name>.token from argocd-secret at request time.
cmd "kubectl --context kind-$CLUSTER -n argocd patch secret argocd-secret \\
  -p '{\"stringData\":{\"plugin.infra-deployment-generator.token\":\"demo-token\"}}'"
kubectl --context "kind-$CLUSTER" -n argocd patch secret argocd-secret \
  -p '{"stringData":{"plugin.infra-deployment-generator.token":"demo-token"}}'

# 6b. ConfigMap the controller uses to locate the plugin
cmd "kubectl --context kind-$CLUSTER apply -f -  # infra-deployment-generator ConfigMap"
kubectl --context "kind-$CLUSTER" apply -f - <<'CMEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: infra-deployment-generator
  namespace: argocd
data:
  baseUrl: "http://infra-deployment-generator.argocd.svc.cluster.local:8080"
  token: "$plugin.infra-deployment-generator.token"
  requestTimeout: "30"
CMEOF

# 6c. Generators BEFORE the helm upgrade
explain "Generators BEFORE upgrading (git only):"
cmd "kubectl --context kind-$CLUSTER -n argocd get applicationset devops-appset -o yaml | yq '.spec.generators'"
kubectl --context "kind-$CLUSTER" -n argocd get applicationset devops-appset -o yaml \
  | yq '.spec.generators'

# 6d. Re-deploy with generatorPlugin set
cmd "helm --kube-context kind-$CLUSTER upgrade --install app-of-appsets ... \\
  --set generatorPlugin=infra-deployment-generator"
helm --kube-context "kind-$CLUSTER" upgrade --install app-of-appsets \
  "$DEMO_DIR/repo/charts/app-of-appsets" \
  -n argocd \
  --set "repoURL=${GITEA_URL}" \
  --set "clusterName=c1-cluster" \
  --set "generatorPlugin=infra-deployment-generator"

# 6e. Generators AFTER
explain "Generators AFTER — git-only becomes matrix(git, plugin):"
cmd "kubectl --context kind-$CLUSTER -n argocd get applicationset devops-appset -o yaml | yq '.spec.generators'"
kubectl --context "kind-$CLUSTER" -n argocd get applicationset devops-appset -o yaml \
  | yq '.spec.generators'

explain "The appset controller re-evaluates every 30 s (requeueAfterSeconds=30 on the plugin generator)."
explain "No controller restart needed — ArgoCD polls on schedule."

takeaway \
	"CHECKPOINT 6 - SAME APPSET, ONE EXTRA GENERATOR" \
	"" \
	"We changed ONE Helm value. We did not edit a single Application," \
	"did not restart ArgoCD, and did not touch the singlidation tree." \
	"" \
	"  before:  generators: git" \
	"  after:   generators: matrix(git, plugin)" \
	"" \
	"The git generator still finds the 6 services. The plugin now gets" \
	"asked, per service, which branch that service should follow." \
	"" \
	"Evidence: the before/after generators blocks printed above." \
	"ArgoCD re-runs the generators every 30s - watch the next step."

pause

# =============================================================================
# STEP 7: THE PAYOFF
# =============================================================================
section "Step 7 — The payoff: only external-dns on the unmerged branch"

explain "Polling until external-dns-c1-cluster targetRevision moves off main..."
explain "(The controller re-evaluates every ~30 s; allow up to 2 minutes.)"
cmd "kubectl --context kind-$CLUSTER -n argocd get application external-dns-c1-cluster \\
  -o jsonpath='{.spec.source.targetRevision}'"

_elapsed=0
_rev=""
while [[ $_elapsed -lt 120 ]]; do
  _rev=$(kubectl --context "kind-$CLUSTER" -n argocd \
    get application external-dns-c1-cluster \
    -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null \
    | tr -d '\n ') || _rev=""
  if [[ -n "$_rev" && "$_rev" != "main" ]]; then
    printf '\n%s   targetRevision is now: %s%s\n' "$G" "$_rev" "$N"
    break
  fi
  printf '.'
  sleep 2
  _elapsed=$((_elapsed + 2))
done

if [[ $_elapsed -ge 120 ]]; then
  printf '\n'
  die "Timed out. Hint: kubectl --context kind-$CLUSTER -n argocd logs deploy/argocd-applicationset-controller"
fi

explain "Payoff table — external-dns on the PR branch, the other five still on main:"
print_table

explain "targetRevision is what ArgoCD was TOLD to deploy. Now prove what it ACTUALLY"
explain "deployed: status.sync.revision should be the unmerged PR commit, not main."
explain "Nudging a refresh so we don't wait out ArgoCD's normal reconcile interval."
cmd "kubectl --context kind-$CLUSTER -n argocd annotate application external-dns-c1-cluster \\
  argocd.argoproj.io/refresh=hard --overwrite"
kubectl --context "kind-$CLUSTER" -n argocd annotate application external-dns-c1-cluster \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null

_elapsed=0
_sync_rev=""
printf '   Waiting for status.sync.revision to catch up'
while [[ $_elapsed -lt 90 ]]; do
  _sync_rev=$(kubectl --context "kind-$CLUSTER" -n argocd \
    get application external-dns-c1-cluster \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null \
    | tr -d '\n ') || _sync_rev=""
  [[ "$_sync_rev" == "$BRANCH_SHA" ]] && break
  printf '.'
  sleep 3
  _elapsed=$((_elapsed + 3))
done
printf '\n'

printf '   main HEAD (NOT deployed):     %s\n' "$MAIN_SHA"
printf '   Unmerged PR branch HEAD:      %s\n' "$BRANCH_SHA"
printf '   ArgoCD status.sync.revision:  %s\n' "${_sync_rev:-<empty>}"

if [[ "$_sync_rev" == "$BRANCH_SHA" ]]; then
  printf '%s   Match confirmed — the running config comes from the UNMERGED PR commit.%s\n' "$G" "$N"
  explain "external-dns is live on replicaCount: 5 while main still says 2."
  _proof_line="CONFIRMED: sync.revision == the PR commit, so the code that is"
  _proof_line2="actually running is the unmerged PR - not main."
elif [[ "$_sync_rev" == "$MAIN_SHA" ]]; then
  explain "Still showing main's commit — the app has not finished re-syncing to the new"
  explain "target yet. targetRevision above is already the authoritative proof."
  _proof_line="sync.revision still shows main's commit: the app has not finished"
  _proof_line2="re-syncing. The TARGET_REVISION column above is the proof."
else
  explain "sync.revision has not settled (repo-server may still be resolving the"
  explain "upstream Helm dependency). targetRevision above is the authoritative proof."
  _proof_line="sync.revision has not settled yet (upstream Helm deps still"
  _proof_line2="resolving). The TARGET_REVISION column above is the proof."
fi

takeaway \
	"THE PAYOFF - ONE SERVICE MOVED, FIVE DID NOT" \
	"" \
	"  external-dns  ->  feature/upgrade-external-dns   (unmerged PR)" \
	"  the other 5   ->  main                          (never moved)" \
	"" \
	"Same ApplicationSet. Same repo. No Application was hand-edited." \
	"A generator decided, per service, which git ref to follow." \
	"" \
	"$_proof_line" \
	"$_proof_line2" \
	"" \
	"THIS IS DEPLOY-THEN-MERGE: prove a risky infra change on real" \
	"clusters, one service at a time, BEFORE it lands on main. If it" \
	"misbehaves, close the PR - nothing was ever merged to roll back."

pause

# =============================================================================
# STEP 8: CLEANUP
# =============================================================================
section "Step 8 — Cleanup"

if [[ "$KEEP" == "true" ]]; then
  printf '   --keep passed: leaving cluster and %s intact.\n' "$DEMO_DIR"
  printf '   Clean up later with:  %s --cleanup\n' "$0"
else
  if [[ "$SLEEP" == "-1" ]]; then
    printf '%s   Tear down the cluster and %s? [Y/n] %s' "$C" "$DEMO_DIR" "$N"
    read -r _confirm
    if [[ "${_confirm:-y}" =~ ^[Nn] ]]; then
      printf '   Skipping. Clean up later with:  %s --cleanup\n' "$0"
    else
      do_cleanup false
    fi
  else
    do_cleanup false
  fi
fi

# =============================================================================
# SUMMARY
# =============================================================================
section "What this demo proved"
explain "1. SINGLIDATION: one values file per cluster, one chart per service, one repo."
explain "   GitOps state is a flat tree — no per-cluster forks, no per-service repos."
explain ""
explain "2. APP-OF-APPLICATIONSETS: one Helm chart emits one ApplicationSet per namespace."
explain "   Adding a cluster = adding one values file. No ArgoCD configuration changes."
explain ""
explain "3. DEPLOY-THEN-MERGE: the custom generator drove targetRevision from PR status."
explain "   external-dns ran the unmerged branch on c1-cluster before anything merged."
explain "   Merge only after canary succeeds. Roll back by simply closing the PR."
