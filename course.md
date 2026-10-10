# Kubernetes + CI/CD: a practical crash course
The best way to learn Kubernetes is to build a small but realistic environment on your own machine, deploy an application, automate its delivery, and then deliberately break things to understand how Kubernetes recovers.

I'll use a setup that resembles how teams operate Kubernetes in production, while keeping everything local and free to experiment with.

By the end, you'll have:
- A local Kubernetes cluster running on your machine.
- A containerized example application.
- A Kubernetes Deployment and Service.
- A CI pipeline that tests your code and builds a Docker image.
- A CD pipeline that deploys new versions automatically after code is committed.
- A GitOps workflow, where Git is the source of truth for what should run in Kubernetes.
- Health checks, resource limits, version history, and rollback capabilities.

## 1. The architecture we'll build
1. Developer commits code
GitHub repository


2. GitHub Actions — CI
Run tests · Build image · Publish image


3. Update the deployment configuration
Commit the new immutable image tag to Git


4. Argo CD — CD
Detect Git changes and reconcile the cluster


5. Local Kubernetes cluster
Pull the image · Replace pods · Run the new version


The important design choice is that GitHub Actions builds and publishes the application, while Argo CD deploys it. We won't give a cloud-hosted CI runner direct access to your local Kubernetes cluster.

This pattern is called GitOps. It's a useful approach to learn because it separates building software from managing the desired state of your infrastructure.

## 2. The tools we'll use
Docker<br>
Builds and runs application containers.

Kubernetes + kind<br>
Kubernetes orchestrates the application; kind creates a local cluster using Docker containers as its nodes.

GitHub Actions<br>
Runs automated tests, builds container images, and publishes them to a registry.

Argo CD<br>
Watches your Git repository and deploys the declared application configuration to Kubernetes.

GitHub Container Registry (GHCR)<br>
Stores the versioned container images that Kubernetes will run.


We'll use a single-node kind cluster initially. You can later add worker nodes or move to a managed Kubernetes service without changing the core concepts.

## 3. Install the prerequisites
I'll assume you're using Linux, macOS, or Windows with WSL2. The commands below use Bash, so they're suitable for Linux and macOS terminals and a WSL2 terminal.
Install these tools:
1. Docker Engine or Docker Desktop — the container runtime. Make sure Docker is running.
2. kubectl — the Kubernetes command-line client.
3. kind — the local Kubernetes cluster manager.
4. Git — version control.
5. A GitHub account — for the source repository, CI workflow, and image registry.

Official installation guides:
- [Docker installation](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [kubectl installation](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start)
- [Git installation](https://git-scm.com/install)

Verify the installations:
```bash
docker version
kubectl version --client
kind version
git --version
```

Make sure the Docker daemon is running before continuing.

## 4. Create your local Kubernetes cluster
A Kubernetes cluster has a control plane that manages the cluster and worker nodes that run your workloads. In this exercise, kind runs the Kubernetes nodes as Docker containers.

Create a cluster:
```bash
kind create cluster --name learning \
  --wait 120s
```

Verify it:
```bash
kubectl config get-contexts
kubectl config current-context
kubectl cluster-info
kubectl get nodes
kubectl get pods -A
```

You should see a context named kind-learning and a node in the Ready state.

The `-A` flag lists resources across all namespaces. Namespaces are logical partitions within a cluster.

Create a namespace for your application:
```bash
kubectl create namespace demo
```

Namespaces help separate applications and their resources. In production, you would also configure access controls and resource quotas where appropriate.

Useful commands to learn immediately:
```bash
kubectl get all -n demo
kubectl describe node
kubectl get events -A --sort-by=.metadata.creationTimestamp
```

The first command will initially show no application resources.

## 5. Build your example application
We'll create a small Python HTTP API. It will expose a version endpoint and health endpoints so you can see the effect of deploying new versions.

Create the project:
```bash
mkdir k8s-demo
cd k8s-demo

mkdir -p tests k8s .github/workflows
```

The project will eventually look like this:
```bash
k8s-demo/
├── app.py
├── requirements.txt
├── requirements-dev.txt
├── Dockerfile
├── .dockerignore
├── tests/
│   └── test_app.py
├── k8s/
│   ├── deployment.yaml
│   └── service.yaml
└── .github/
    └── workflows/
        └── ci-cd.yaml
```


### 5.1 Create the application
Create `app.py`:
```python
import os

from flask import Flask, jsonify

app = Flask(__name__)

VERSION = os.getenv("APP_VERSION", "local")


@app.get("/")
def index():
    return jsonify(
        application="k8s-demo",
        version=VERSION,
        message="Hello from Kubernetes!"
    )


@app.get("/healthz")
def health():
    return "", 200


@app.get("/readyz")
def ready():
    return "", 200
```



Create `requirements.txt`:
```
Flask>=3.1,<4
gunicorn>=23,<24
```

Create `requirements-dev.txt`:
```
-r requirements.txt
pytest>=8,<10
```

The application uses Gunicorn to run Flask. The version is supplied through an environment variable, allowing us to change the version without changing the application code.

The health endpoints have distinct purposes:
- /healthz indicates whether the process is healthy.
- /readyz indicates whether it is ready to receive requests.

For this small stateless example, both return success. A real application should check the dependencies necessary to serve requests before reporting readiness.

### 5.2 Write a test
Create `tests/test_app.py`:
```python
from app import app


def test_index():
    client = app.test_client()

    response = client.get("/")

    assert response.status_code == 200
    assert response.json["application"] == "k8s-demo"


def test_health():
    response = app.test_client().get("/healthz")

    assert response.status_code == 200
```

Create `pytest.ini`:
```ini
[pytest]
pythonpath = .
testpaths = tests
```


Run the tests:
```bash
python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements-dev.txt
pytest -q
```

On Windows PowerShell, activate the environment with `.venv\Scripts\Activate.ps1` instead.

You should see two passing tests.

## 6. Containerize the application
Create a `Dockerfile`:
```Dockerfile
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=local

WORKDIR /app

RUN addgroup --system app \
    && adduser --system --ingroup app app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER app

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", \
     "--workers", "2", "--access-logfile", "-", "app:app"]
```

Create `.dockerignore`:
```
.git
.venv
__pycache__
.pytest_cache
tests
```

Build and run the container:
```bash
docker build -t k8s-demo:local .

docker run --rm -p 8080:8080 \
  -e APP_VERSION=local \
  k8s-demo:local
```

In another terminal:
```bash
curl http://localhost:8080/
curl http://localhost:8080/healthz
```

Stop the container with Ctrl+C.

**Best practices demonstrated**: a slim base image, a non-root user, an explicit listening port, and configuration supplied through environment variables. For production, also pin the base image by digest, scan dependencies and images for vulnerabilities, and use a controlled dependency-locking strategy.

## 7. Deploy the application to Kubernetes
Kubernetes works from declarative manifests: you specify the desired state, and Kubernetes attempts to maintain it.

We'll create two resources:
- A **Deployment**, which manages application replicas and updates.
- A **Service**, which provides a stable network endpoint for those replicas.

### 7.1 Create the Deployment
Create `k8s/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-demo
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: k8s-demo
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: k8s-demo
    spec:
      containers:
        - name: app
          image: ghcr.io/OWNER/k8s-demo:bootstrap
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: APP_VERSION
              value: "bootstrap"
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
          startupProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            periodSeconds: 10
      terminationGracePeriodSeconds: 30
```

Replace **OWNER** with your lowercase GitHub username or organization. The image tag will be updated by our pipeline.

The `bootstrap` tag is a placeholder; don't apply this manifest yet. The pipeline will publish a real image tag before we connect Argo CD.

Important concepts:
- `replicas`: 2 asks Kubernetes to maintain two application instances.
- `RollingUpdate` allows a controlled replacement of pods.
- `maxUnavailable`: 0 requests that the Deployment avoid reducing the available replica count during the rollout, subject to capacity and readiness.
- Resource requests help Kubernetes schedule pods; limits constrain resource consumption.
- Probes let Kubernetes distinguish startup, readiness, and liveness.

## 7.2 Create the Service
Create `k8s/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: k8s-demo
  namespace: demo
spec:
  type: ClusterIP
  selector:
    app: k8s-demo
  ports:
    - name: http
      port: 80
      targetPort: http
```

The Service routes traffic to ready pods matching `app: k8s-demo`. `ClusterIP` makes it reachable inside the cluster without exposing it directly to your network.

### 7.3 Learn the manual deployment workflow first
Before automating everything, understand the normal deployment lifecycle.

Build a tagged image and load it into kind:
```bash
docker build -t k8s-demo:v1 .

kind load docker-image k8s-demo:v1 --name learning
```

Temporarily change the Deployment image to `k8s-demo:v1` and its `APP_VERSION` to `v1`.

Because the image was loaded directly into kind, set `imagePullPolicy: IfNotPresent` on the container for this local-only test. This avoids trying to pull the image from a remote registry.

Then apply the manifests:
```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
```

Check the rollout:
```bash
kubectl rollout status deployment/k8s-demo -n demo
kubectl get pods -n demo -o wide
kubectl get deployment,service -n demo
```

Open another terminal and forward a local port:
```bash
kubectl port-forward -n demo \
  service/k8s-demo 8080:80
```

Now visit http://localhost:8080/ or run:
```bash
curl http://localhost:8080/
```

You should receive JSON containing `"version":"v1"`.

Once you've confirmed this works, revert the Deployment image to the GHCR placeholder. We'll let GitOps manage the configuration from here on.

Kubernetes' [Deployment documentation](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) and kind's [quick start](https://kind.sigs.k8s.io/docs/user/quick-start) explain these mechanics in more detail. 

## 8. Put the project in GitHub
Create an empty GitHub repository named `k8s-demo`. Do not initialize it with a README, because you've already created the project locally.

Initialize your local repository:
```bash
git init
git add .
git commit -m "feat: add initial application and Kubernetes manifests"
git branch -M main
git remote add origin https://github.com/OWNER/k8s-demo.git
git push -u origin main
```

Replace `OWNER` with your GitHub username or organization.

Your first push is just source control. We'll now configure GitHub Actions to test and publish the application automatically.

## 9. Configure continuous integration and delivery

There are two related but distinct processes:
- **CI (continuous integration)**: test the code and build a deployable artifact.
- **CD (continuous delivery/deployment)**: update the desired application version and make it run in Kubernetes.

For this exercise, we'll implement CI using GitHub Actions and CD using Argo CD.

### 9.1 Create the workflow
Create `.github/workflows/ci-cd.yaml`:
```yaml
name: CI and publish

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v6
        with:
          python-version: "3.13"

      - name: Install dependencies
        run: pip install -r requirements-dev.txt

      - name: Run tests
        run: pytest -q

  publish:
    needs: test
    if: github.event_name == 'push'
    runs-on: ubuntu-latest

    permissions:
      contents: write
      packages: write

    steps:
      - uses: actions/checkout@v4

      - name: Set image name
        id: image
        run: |
          echo "name=ghcr.io/${GITHUB_REPOSITORY,,}" \
            >> "$GITHUB_OUTPUT"

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ steps.image.outputs.name }}:${{ github.sha }}

      - name: Update deployment manifest
        env:
          IMAGE: ${{ steps.image.outputs.name }}
          VERSION: ${{ github.sha }}
        run: |
          sed -i -E \
            "s|image: ghcr.io/OWNER/k8s-demo:.*|image: ${IMAGE}:${VERSION}|" \
            k8s/deployment.yaml

          sed -i -E \
            "s|value: \"bootstrap\"|value: \"${VERSION}\"|" \
            k8s/deployment.yaml

      - name: Commit deployment configuration
        run: |
          git config user.name "github-actions[bot]"
          git config user.email \
            "41898282+github-actions[bot]@users.noreply.github.com"

          git add k8s/deployment.yaml

          if ! git diff --cached --quiet; then
            git commit -m "deploy: update image to ${GITHUB_SHA}"
            git push
          fi
```

This workflow uses a few useful patterns:
- Tests must pass before publishing an image.
- Pull requests run tests but do not publish deployment artifacts.
- Each image is tagged with the full Git commit SHA, rather than a mutable latest tag.
- The image is published to GHCR.
- The manifest is committed with the new image reference.
- The `GITHUB_TOKEN` is used instead of a long-lived personal access token.

The workflow's `OWNER` placeholder in the sed command must match the one in your manifest. If you use a different image path, adjust it accordingly.

The branch can be `main` or `master`. Adjust it accordingly.

The official [GitHub Actions container publishing](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images) guide covers image publishing and registry permissions. 

### 9.2 Make the container package public
For the simplest local learning setup, make the GHCR package public after the first successful publication.

In GitHub, open the repository's published package under your account's Packages section, then open its package settings and change its visibility to public.

This lets your local Kubernetes cluster pull the image without registry credentials.

For a private production package, use a narrowly scoped read-only pull credential or another supported registry authentication mechanism. Never commit registry credentials into Git.

### 9.3 Verify CI
Push the workflow:
```bash
git add .
git commit -m "ci: add automated build and publish"
git push
```

Open the repository's `Actions` tab in GitHub.

Verify that:
1. The tests pass.
2. The container image builds successfully.
3. The image is published to GHCR.
4. A new commit updates k8s/deployment.yaml with the commit SHA.

Inspect the deployment manifest:
```bash
git pull
grep -E 'image:|APP_VERSION|value:' k8s/deployment.yaml
```

The image should now resemble:
```
ghcr.io/your-user/k8s-demo:<full-commit-sha>
```

At this point, CI is working. CD isn't connected yet.

**A note on production hardening**

The workflow above is deliberately approachable for a first lab. Before using it in a production repository, improve it by:
- Pinning third-party GitHub Actions to verified full commit SHAs.
- Restricting which branches and identities can publish images.
- Using dependency and image vulnerability scanning.
- Adding a protected promotion step for production.
- Avoiding direct writes to a protected deployment branch without review.
- Using a pull request to change the deployment configuration when approval is required.

For this exercise, an automatically committed manifest is a straightforward way to demonstrate GitOps. A more mature setup often uses a separate deployment repository or pull requests for environment promotion.

## 10. Install Argo CD into your cluster
Argo CD will continuously compare your Git manifests with the actual cluster state and apply changes according to its synchronization policy.

Install it into a dedicated namespace:
```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for the components to become ready:
```bash
kubectl wait \
  --for=condition=Ready pods \
  --all -n argocd \
  --timeout=300s
```

Check the installed resources:
```bash
kubectl get pods -n argocd
```

For a learning environment, the stable installation manifest is convenient. For production, pin and test a specific Argo CD release instead of relying on a moving stable reference. 

### 10.1 Open the Argo CD interface
Forward its server port to your machine:
```bash
kubectl port-forward \
  -n argocd service/argocd-server 8081:443
```

Keep this terminal open. Visit:

https://localhost:8081

The default installation uses a self-signed certificate, so your browser may show a certificate warning.

In another terminal, retrieve the initial administrator password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

echo
```

The username is `admin`.

Use this only for the local lab. Do not expose the Argo CD server publicly or leave default administrator credentials in place in production. The port-forward command provides a local access path without exposing the service on your LAN.

## 11. Connect Argo CD to your Git repository
We'll declare an Argo CD Application. This object tells Argo CD which repository and directory to watch, which cluster to deploy to, and whether to synchronize automatically.

Create `argocd-application.yaml` locally, but do not put it inside the directory Argo CD will manage. Instead, keep it at the project root, or use the following command to create it there:
```bash
cat > argocd-application.yaml <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: k8s-demo
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/OWNER/k8s-demo.git
    targetRevision: main
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

Replace `OWNER` with your GitHub username or organization.

Set `targetRevision` to `main` or `master`.

The repository must be readable by Argo CD. Public repositories work without additional credentials; for private repositories, configure repository credentials securely.

Apply the application definition:
```bash
kubectl apply -f argocd-application.yaml
```

Check the status:
```bash
kubectl get applications -n argocd
kubectl get pods -n demo
kubectl get deployment,service -n demo
```

You can also inspect the application in the Argo CD UI.

The synchronization policy is important:
- `automated` tells Argo CD to deploy Git changes automatically.
- `prune`: true allows it to remove managed resources deleted from Git.
- `selfHeal`: true allows it to correct certain manual changes made directly to the cluster.
- `CreateNamespace=true` lets Argo CD create the destination namespace if necessary.

**Warning**: automatic pruning and self-healing are useful, but they also mean a bad Git change can be applied automatically. Use code review, environment separation, and promotion controls before adopting this pattern for production. 

## 12. Test the complete CI/CD pipeline
Now comes the important part: verify that a code commit actually results in a new version running in Kubernetes.

### 12.1 Confirm the initial deployment
First, ensure the image referenced in `k8s/deployment.yaml` exists in GHCR and is publicly readable.

If Argo CD reports an image-pull error, check the image name, tag, and package visibility. Once the package is public and the manifest references a valid image, Argo CD should reconcile the application.

Check the rollout:
```bash
kubectl rollout status deployment/k8s-demo -n demo
kubectl get pods -n demo
kubectl get deployment k8s-demo -n demo
```

Forward the Service port:
```bash
kubectl port-forward -n demo \
  service/k8s-demo 8080:80
```

In another terminal:
```bash
curl -s http://localhost:8080/
```

You should see JSON similar to:
```json
{
  "application": "k8s-demo",
  "version": "<commit-sha>",
  "message": "Hello from Kubernetes!"
}
```

The version should match the image tag recorded in Git.

### 12.2 Correct two lines in the workflow before testing subsequent commits
The workflow in section 9 uses an initial placeholder in its manifest update commands. For repeat deployments, those commands must match the real image path and replace the previous version, not just the initial placeholder.

In `.github/workflows/ci-cd.yaml`, use these commands in the Update deployment manifest step:
```bash
sed -i -E \
  "s|image: ghcr.io/.*/k8s-demo:.*|image: ${IMAGE}:${VERSION}|" \
  k8s/deployment.yaml

sed -i -E \
  "s|value: \".*\"|value: \"${VERSION}\"|" \
  k8s/deployment.yaml
```

This assumes the application image path ends in `/k8s-demo` and that the `APP_VERSION` value is the only quoted `value` field in this manifest. If you change the manifest structure, update the commands accordingly.

Make sure the image in the manifest initially uses the correct placeholder form:
```yaml
image: ghcr.io/OWNER/k8s-demo:bootstrap
```

Here, `OWNER` should be replaced with your lowercase GitHub username or organization. The workflow's generalized image update will then work on subsequent commits.

### 12.3 Make a change and deploy it
Change the message in `app.py`:
```python
message="Hello from Kubernetes! Version 2"
```

Commit and push the change:
```bash
git add app.py
git commit -m "feat: update application message"
git push
```

Follow the process in GitHub Actions:
1. The tests run.
2. The new image is built and published with the new commit SHA.
3. The deployment manifest is updated and pushed to Git.
4. Argo CD detects the Git change.
5. Kubernetes rolls out the new pods.

Watch the rollout:
```bash
kubectl rollout status deployment/k8s-demo -n demo
kubectl get pods -n demo -w
```

When the rollout completes, query the application again:
```bash
curl -s http://localhost:8080/
```

You should see the updated message and new version.

You've now implemented an automated path from a code commit to a running application, without a CI runner connecting directly to your local cluster.

### 13. Learn to troubleshoot Kubernetes
Troubleshooting is one of the most valuable skills you can develop. Learn these commands early.


| Problem                 | Command                                                            |
| :---------------------- | :----------------------------------------------------------------- |
| Pod isn't starting      | `kubectl get pods -n demo`                                         |
| Pod details and events  | `kubectl describe pod -n demo POD_NAME`                            |
| Application logs        | `kubectl logs -n demo deployment/k8s-demo`                         |
| Previous container logs | `kubectl logs -n demo POD_NAME --previous`                         |
| Deployment rollout      | `kubectl rollout status deployment/k8s-demo -n demo`               |
| Rollout history         | `kubectl rollout history deployment/k8s-demo -n demo`              |
| Service endpoints       | `kubectl get endpointslices -n demo`                               |
| Cluster events          | `kubectl get events -n demo --sort-by=.metadata.creationTimestamp` |
| Argo CD application     | `kubectl describe application k8s-demo -n argocd`                  |


Three common failures to reproduce deliberately:

`ImagePullBackOff`<br>
Kubernetes cannot pull the image. Check the registry path, tag, visibility, and authentication.

`CrashLoopBackOff`<br>
The container repeatedly exits. Inspect its logs, command, configuration, and resource constraints.

Argo CD reports `OutOfSync`<br>
Compare Git with the live resources, inspect synchronization errors, and check whether the application is configured for automatic sync.

### 13.1 Practice a rollback
In GitOps, the cleanest rollback is generally to revert the Git commit that introduced the bad deployment configuration.

For example:
```bash
git log --oneline
git revert <bad-commit-sha>
git push
```

If the reverted commit changed application code, CI will build a new image from that reverted source and publish it. Argo CD will then reconcile the configuration.

If only the deployment manifest changed, the revert can restore the previous image reference directly.

You can inspect Kubernetes' rollout history with:
```bash
kubectl rollout history deployment/k8s-demo -n demo
```

However, avoid manually running kubectl rollout undo as your normal GitOps rollback procedure: Argo CD may reconcile the cluster back to the state recorded in Git.

## 14. Best practices to take away
The lab demonstrates the core workflow. Here are the practices worth carrying into real projects.

| Area                | Recommended practice                                                                             |
| :------------------ | :----------------------------------------------------------------------------------------------- |
| Images              | Use immutable tags or digests; avoid latest for deployments.                                     |
| Containers          | Run as non-root, minimize the base image, and scan for vulnerabilities.                          |
| Kubernetes          | Define resources, health probes, replica counts, and rollout behavior.                           |
| Configuration       | Keep configuration outside the application image.                                                |
| Secrets             | Use a secret manager or an appropriate Kubernetes secrets solution; never commit secrets to Git. |
| CI                  | Run tests and security checks before publishing artifacts.                                       |
| CD                  | Use GitOps, declarative manifests, and auditable changes.                                        |
| Access control      | Apply least privilege to CI credentials and Kubernetes service accounts.                         |
| Production releases | Use protected branches, review, and explicit promotion between environments.                     |
| Observability       | Collect application logs, metrics, and alerts.                                                   |

A few important nuances:
- Kubernetes Secrets are not automatically a complete secrets-management solution. Their security depends on access controls, encryption at rest, and how they're distributed.
- Two replicas on a single-node cluster do not provide protection against losing that node.
- A successful rolling update does not guarantee that an application is functionally correct. Automated smoke tests and monitoring are also important.
- An image tag based on a commit SHA is a useful immutable naming convention, but the registry must also prevent overwriting existing tags if you want immutability to be enforced.

## 15. Your next learning milestones
Once this lab works, progress through these stages in order.

**Learning checklist**

**Stage 1 — Kubernetes fundamentals**
- Create a ConfigMap and a Secret.
- Scale the Deployment to three replicas.
- Break a readiness probe and observe traffic behavior.
- Experiment with namespaces and resource limits.

**Stage 2 — Application packaging**
- Introduce Helm or Kustomize.
- Separate development and production configurations.
- Add persistent storage if your application needs it.

**Stage 3 — Production-style CI/CD**
- Build and scan images in CI.
- Deploy to a staging environment first.
- Use pull requests to promote image versions.
- Add automated smoke tests and a rollback procedure.

**Stage 4 — Cluster operations**
- Install an Ingress controller and configure local routing.
- Learn NetworkPolicies and RBAC.
- Add Prometheus and Grafana for metrics.
- Practice cluster upgrades and backup/restore.


## 16. Useful official documentation
These are the resources I would keep open while working through the exercises.
- [Kubernetes — Learn Kubernetes Basics](https://kubernetes.io/docs/tutorials/kubernetes-basics/) — deployments, scaling, and application exposure.
- [Kubernetes — Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — rolling updates and rollout history.
- [kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start) — cluster creation and local image loading.
- [GitHub Actions — Publishing Docker images](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images) — automated image publishing.
- [Argo CD — Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/) — installation and initial configuration.
- [Argo CD — Automated Sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/) — GitOps reconciliation.

## 17. Clean up when you're finished
When you want to remove the local lab, delete the cluster:
```bash
kind delete cluster --name learning
```

This deletes the Kubernetes resources inside that kind cluster, including Argo CD and your application. It does not delete your GitHub repository or the images stored in GHCR.

---

**My recommendation**: don't start with a multi-node cluster, service mesh, Helm charts, and several monitoring systems all at once. First get the application working manually, then automate image publishing, and finally introduce Argo CD. Understanding each transition will teach you much more than deploying a large prebuilt platform without knowing how its components fit together.