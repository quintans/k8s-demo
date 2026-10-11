# Stage 3 — Production-style CI/CD

## Goal

Improve the pipeline so that:
1. Every pull request is tested.
2. The application image is built once and scanned for vulnerabilities.
3. Images have immutable version identifiers.
4. A successful build proposes a deployment change through a pull request.
5. Staging and production are promoted deliberately.
6. Argo CD deploys only configuration that has been committed to Git.

This replaces the direct manifest push from the initial tutorial with a reviewable deployment workflow.

### Step 3.1 — Separate build and deployment responsibilities
The flow will now be:

**Pull request**<br>
Test application code

**Merge to main**<br>
Build image · Scan image · Publish image

**Deployment pull request**<br>
Update the dev image tag

**Argo CD**<br>
Deploy after the PR is merged

For a learning project, you can keep application code and Kubernetes configuration in the same repository. Larger organizations often use a separate deployment repository so application contributors don't automatically gain control over every environment.

### Step 3.2 — Add image vulnerability scanning
Install Trivy locally if you want to experiment interactively, or add it to GitHub Actions. We'll add it to CI.

The Trivy action can scan a locally built container image and fail the workflow when vulnerabilities of specified severities are found. 

In your workflow, after building the image, add a scan step such as:
```yaml
      - name: Scan image
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ghcr.io/${{ github.repository }}:${{ github.sha }}
          format: table
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"
```

This step must run **after the image has been built and before it is published**, or you must otherwise make the image available to the scanner. For a local image build, ensure it is tagged with the same name used by `image-ref`.

For stronger security, pin the action to a verified full commit SHA and review the scanner's vulnerability database and failure policy. `ignore-unfixed: true` is a deliberate learning choice; it doesn't mean the remaining vulnerabilities are harmless.

### Step 3.3 — Merge and verify the deployment
The process should now be:
1. Push application code to a feature branch.
2. Open a pull request.
3. Verify tests pass.
4. Merge the application change into `main` or `master`.
5. Verify that the image is built, scanned and published.
6. Review and merge the generated deployment pull request.
7. Watch Argo CD synchronize the updated development overlay.

Verify the result:
```bash
kubectl rollout status deployment/k8s-demo -n demo
kubectl get deployment k8s-demo -n demo
kubectl get pods -n demo
```

Check that the image tag matches the commit SHA:
```bash
kubectl get deployment k8s-demo -n demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

echo
```

This establishes an auditable chain from source code to image to deployment configuration.

### Step 3.4 — Promote to staging and production

A good release workflow promotes a known, tested image rather than rebuilding it separately for every environment.

For this lab, promote by updating the newTag in each overlay:
```bash
k8s/overlays/dev/kustomization.yaml
k8s/overlays/staging/kustomization.yaml
k8s/overlays/prod/kustomization.yaml
```

The process is:
1. Merge the deployment PR for development.
2. Run smoke tests against the development deployment.
3. Open a staging promotion PR that sets the same image SHA in staging.
4. Merge after the staging checks pass.
5. Open a production promotion PR that sets the same SHA in prod.
6. Merge only after the required approval and release checks.

The image SHA should remain identical throughout the promotion. Environment differences belong in configuration, not in separately rebuilt images.

To run staging and production simultaneously on your local cluster, create separate Argo CD Applications targeting the `staging` and `prod` overlays. Each destination namespace must exist or be configured for creation. Remember that separate namespaces on one node are not equivalent to separate, isolated production environments.

For production, protect the branch, require review, configure CI status checks, and restrict who can approve deployment changes.

### Step 3.5 — Add smoke tests
A smoke test checks that the deployed service behaves correctly, not merely that its container starts.

After a deployment, run a test such as:
```bash
kubectl port-forward -n demo service/k8s-demo 8080:80
```

In another terminal:
```bash
curl --fail --silent --show-error http://localhost:8080/
```

For a more complete test, assert that the response contains the expected application name and deployed version. In a real CI/CD system, run smoke tests from an environment that can reach the deployed service, and make promotion dependent on their success.

What we learned:
- Pull requests run tests without deploying.
- Published images have immutable commit-based identifiers.
- Images are scanned before release.
- Deployment changes are reviewed through pull requests.
- The same image is promoted through development, staging and production.
- A failed smoke test blocks further promotion.