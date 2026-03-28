# Custom ApplicationSet Generator — Infra Deployment Plugin

This is an ArgoCD ApplicationSet [custom plugin generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Plugin/) that enables the **deploy-then-merge** pattern.

## How It Works

```
PR Created → CI sets commit statuses → Generator reads statuses
→ Returns branch overrides → ApplicationSet deploys PR branch
→ Only affected services get the override → Everything else stays on main
```

## Deploying to ArgoCD

### 1. Build and push the image

```bash
docker build -t your-registry/infra-deployment-generator:latest .
docker push your-registry/infra-deployment-generator:latest
```

### 2. Register as an ApplicationSet plugin

Add to your ArgoCD ConfigMap (`argocd-cm`):

```yaml
data:
  applicationsetcontroller.plugin.generators: |
    - name: infra-deployment-generator
      baseUrl: http://infra-deployment-generator.argocd.svc.cluster.local:8080
```

### 3. Deploy the generator

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: infra-deployment-generator
  namespace: argocd
spec:
  replicas: 2
  selector:
    matchLabels:
      app: infra-deployment-generator
  template:
    spec:
      containers:
        - name: generator
          image: your-registry/infra-deployment-generator:latest
          ports:
            - containerPort: 8080
          env:
            - name: GITHUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: github-token
                  key: token
            - name: GITHUB_REPO
              value: "your-org/your-singlidation-repo"
```

## Extending the Generator

Open `generator.py` and look for the `TODO` comments. The key function to implement is `get_active_deployments()` — replace the mock data with real GitHub GraphQL queries.

### What to implement:
1. **GitHub GraphQL client** — Query PRs with commit statuses
2. **Phase filtering** — Match deployment phases to cluster/namespace
3. **File analysis** — Extract affected services from PR changed files
4. **Caching** — Cache GitHub responses (statuses don't change every second)

## Testing Locally

```bash
pip install -r requirements.txt
python generator.py

# In another terminal:
curl -X POST http://localhost:8080/api/v1/getparams.execute \
  -H "Content-Type: application/json" \
  -d '{"input":{"parameters":{"namespace":"devops","clusterName":"us-prod-1"}}}'
```

Expected response (mock):
```json
{
  "output": {
    "parameters": [{
      "infraDeployBranches": {
        "external-dns": "feature/upgrade-external-dns"
      }
    }]
  }
}
```
