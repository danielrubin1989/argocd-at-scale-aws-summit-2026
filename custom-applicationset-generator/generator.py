"""
Infra Deployment Generator — ArgoCD ApplicationSet Custom Plugin

This generator enables the deploy-then-merge pattern for safe infrastructure changes.
Instead of merging to main and deploying everywhere at once, it allows deploying
a PR branch to specific services/clusters BEFORE merging.

How it works:
1. A CI pipeline (e.g., Harness, GitHub Actions) sets commit statuses on PRs
   to signal which deployment phase is active
2. This generator reads those statuses via the GitHub GraphQL API
3. It analyzes which files changed in the PR to determine affected services
4. It returns branch overrides: { "service-name": "feature/branch" }
5. The ApplicationSet template uses this to set targetRevision per service

When no PR deployment is active, returns an empty map — all services stay on main.
"""

import json
import logging
import os

from flask import Flask, request, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "danielrubin1989/argocd-at-scale-aws-summit-2026")

# Mock configuration (env-driven so the demo works without GitHub credentials)
MOCK_ENABLED = os.environ.get("MOCK_ENABLED", "true")
MOCK_PR_NUMBER = int(os.environ.get("MOCK_PR_NUMBER", "42"))
MOCK_BRANCH = os.environ.get("MOCK_BRANCH", "feature/upgrade-external-dns")
MOCK_NAMESPACE = os.environ.get("MOCK_NAMESPACE", "devops")
MOCK_CLUSTERS = os.environ.get("MOCK_CLUSTERS", "c1-cluster").split(",")
MOCK_SERVICES = os.environ.get("MOCK_SERVICES", "external-dns").split(",")


# =============================================================================
# TODO: Implement your GitHub integration here
# =============================================================================
#
# In a real implementation, you would:
#
# 1. Query GitHub GraphQL API for open PRs with deployment statuses:
#
#    query {
#      repository(owner: "org", name: "repo") {
#        pullRequests(states: OPEN, first: 50) {
#          nodes {
#            number
#            headRefName
#            commits(last: 1) {
#              nodes {
#                commit {
#                  status {
#                    contexts {
#                      context    # e.g., "Infra-Deployment/PHASE=canary"
#                      state      # SUCCESS, PENDING, FAILURE
#                    }
#                  }
#                }
#              }
#            }
#            files(first: 100) {
#              nodes { path }
#            }
#          }
#        }
#      }
#    }
#
# 2. Filter PRs by deployment phase matching the requested cluster/namespace
#
# 3. Extract changed service names from file paths:
#    "singlidation/devops/external-dns/values-global.yaml" -> "external-dns"
#
# 4. Return branch overrides for affected services
# =============================================================================


def get_active_deployments(namespace: str, cluster_name: str) -> dict:
    """
    Query GitHub for active PR deployments targeting this namespace/cluster.

    Returns:
        dict: Map of service_name -> branch_name for services being deployed
              from a PR branch. Empty dict means all services use main.

    TODO: Replace this mock with real GitHub GraphQL queries.
    """

    # =========================================================================
    # MOCK IMPLEMENTATION — Replace with real logic
    # =========================================================================
    #
    # This mock simulates a PR (#42) deploying external-dns changes
    # to the devops namespace. In production, this data would come from
    # GitHub commit statuses set by your CI pipeline.

    if MOCK_ENABLED.lower() not in ("true", "1", "yes"):
        return {}

    mock_active_prs = [
        {
            "pr_number": MOCK_PR_NUMBER,
            "branch": MOCK_BRANCH,
            "namespace": MOCK_NAMESPACE,
            "phase": "canary",
            "target_clusters": MOCK_CLUSTERS,
            "changed_services": MOCK_SERVICES,
        }
    ]

    branch_overrides = {}
    for pr in mock_active_prs:
        if pr["namespace"] != namespace:
            continue
        if cluster_name not in pr["target_clusters"]:
            continue

        for service in pr["changed_services"]:
            branch_overrides[service] = pr["branch"]
            logger.info(
                "PR #%d: overriding %s -> %s (phase: %s)",
                pr["pr_number"],
                service,
                pr["branch"],
                pr["phase"],
            )

    return branch_overrides


@app.route("/api/v1/getparams.execute", methods=["POST"])
def generate():
    """
    ApplicationSet plugin endpoint.

    ArgoCD calls this with the input parameters defined in the ApplicationSet spec.
    Must return a JSON array of parameter sets that get merged into the template.
    """
    body = request.get_json(silent=True) or {}
    input_params = body.get("input", {}).get("parameters", {})

    namespace = input_params.get("namespace", "")
    cluster_name = input_params.get("clusterName", "")

    logger.info("Generator called: namespace=%s cluster=%s", namespace, cluster_name)

    # Get branch overrides for active deployments
    branch_overrides = get_active_deployments(namespace, cluster_name)

    # Return a single parameter set with the infraDeployBranches map
    # The ApplicationSet template reads this to decide targetRevision per service
    result = {
        "output": {
            "parameters": [
                {
                    "infraDeployBranches": branch_overrides,
                }
            ]
        }
    }

    logger.info("Returning: %s", json.dumps(result, indent=2))
    return jsonify(result)


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
