# Stage 1 — Kubernetes fundamentals

We'll continue from the k8s-demo project, the kind cluster named learning, GitHub Actions, GHCR, and Argo CD that we set up in the previous tutorial.

## Goal
Learn how to configure an application without rebuilding its image, scale it, understand health probes, and restrict resource consumption.

### Step 1.0 - recreate kind cluster

If the kind cluster was delete use the following commands to recreate it:

```bash
kind create cluster --name learning --wait 120s

kubectl create namespace argocd

kubectl apply -n argocd \
  --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -f argocd-application.yaml
```

To open the Argo CD interface see [### 10.1 Open the Argo CD interface](../00-basics/README.md#101-open-the-argo-cd-interface).

### Step 1.1 — Move configuration into a ConfigMap
A ConfigMap stores non-sensitive configuration separately from the container image. This lets you run the same image with different settings in different environments. 

Create `k8s/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k8s-demo-config
  namespace: demo
data:
  APP_MESSAGE: "Hello from Kubernetes (ConfigMap)"
  LOG_LEVEL: "info"
```

Change the Deployment to consume the ConfigMap. In `k8s/deployment.yaml`, replace the existing `APP_VERSION` environment variable section with:
```yaml
          env:
            - name: APP_VERSION
              value: "bootstrap"
            - name: APP_MESSAGE
              valueFrom:
                configMapKeyRef:
                  name: k8s-demo-config
                  key: APP_MESSAGE
            - name: LOG_LEVEL
              valueFrom:
                configMapKeyRef:
                  name: k8s-demo-config
                  key: LOG_LEVEL
```

Update `app.py` so the message is configurable:
```python
MESSAGE = os.getenv("APP_MESSAGE", "Hello from Kubernetes!")


@app.get("/")
def index():
    return jsonify(
        application="k8s-demo",
        version=VERSION,
        message=MESSAGE
    )
```

Apply the ConfigMap:
```bash
kubectl apply -f k8s/configmap.yaml
```

Commit both files to Git and push them. Since Argo CD manages your application, let it synchronize the changes.

Check the result:
```bash
kubectl get configmap -n demo
kubectl rollout status deployment/k8s-demo -n demo
```

Forward the Service port:
```bash
kubectl port-forward -n demo service/k8s-demo 8080:80
```

In another terminal query the application:
```bash
curl -s http://localhost:8080/
```

You should see JSON similar to:
```json
{
  "application": "k8s-demo",
  "version": "<commit-sha>",
  "message": "Hello from Kubernetes (ConfigMap)"
}
```

**Experiment**: change `APP_MESSAGE` in `k8s/configmap.yaml` and push another commit.

An important detail: ConfigMap values consumed as environment variables are read when the container starts. Updating a ConfigMap does not automatically update existing environment variables inside running containers. Restart the Deployment when you need to reload them:
```bash
kubectl rollout restart deployment/k8s-demo -n demo
```

For GitOps, make the restart part of your deliberate deployment workflow rather than treating manual commands as the normal solution.

### Step 1.2 — Understand Secrets
A Kubernetes Secret holds sensitive configuration, such as passwords or API tokens.

For this exercise, create a dummy password directly in the cluster:
```bash
kubectl create secret generic demo-credentials \
  -n demo \
  --from-literal=DEMO_PASSWORD='not-a-real-password'
```

Reference it in the Deployment:
```yaml
          env:
            - name: DEMO_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: demo-credentials
                  key: DEMO_PASSWORD
```

Check that the Secret exists:
```bash
kubectl describe secret demo-credentials -n demo
```

The output shows the key and the size of its value, rather than displaying the password.

A few rules:
- Don't commit real credentials or unencrypted secret values to Git.
- Base64 encoding in a Secret manifest is not encryption.
- Restrict who can read Secrets using RBAC.
- For a real deployment, use encryption at rest and consider a dedicated secrets manager.

For this lab, the Secret is created imperatively and is not managed by Argo CD. This is intentional: later, you'll learn how to integrate secret management into a declarative workflow without storing the secret itself in Git.

### Step 1.3 — Scale the application
Run:
```bash
kubectl scale deployment/k8s-demo \
  --replicas=3 -n demo
```

Inspect the result:
```bash
kubectl get deployment,pods -n demo
```

You should see three pods.

Now delete one:
```bash
kubectl delete pod -n demo \
  "$(kubectl get pods -n demo -l app=k8s-demo \
    -o jsonpath='{.items[0].metadata.name}')"
```

Run `kubectl get pods -n demo` again. The Deployment controller should create a replacement pod.

This is the reconciliation principle at the heart of Kubernetes: you specify the desired state, and controllers continually try to make the actual state match it.

**GitOps warning**: if your Deployment manifest still says replicas: 2, Argo CD may reset your manual scale operation to two replicas. To make three replicas permanent, update the manifest in Git and let Argo CD apply it.

### Step 1.4 — Test resource limits
Your Deployment already declares CPU and memory requests and limits.

Inspect them:
```bash
kubectl describe deployment k8s-demo -n demo
kubectl top pods -n demo
```

The `kubectl top` command requires Metrics Server. If it is not installed, the command may report that metrics are unavailable; that is not necessarily a problem with your application.

The distinction is important:
- **Requests** influence scheduling and resource allocation.
- **Limits** cap resource consumption. A container exceeding its memory limit can be terminated; CPU limits can throttle it.

Try lowering the memory limit to `16Mi` in Git, push the change, and observe the rollout and pod events. The application might fail to start, depending on its actual memory requirements.

Restore the previous value after the experiment.

### Step 1.5 — Explore readiness and liveness probes
Your application exposes `/readyz` and `/healthz`. Temporarily change the readiness probe path to a non-existent endpoint in Git:
```yaml
          readinessProbe:
            httpGet:
              path: /does-not-exist
              port: http
            periodSeconds: 5
```

Push the change and inspect the pods:
```bash
kubectl get pods -n demo
kubectl describe pod -n demo POD_NAME
```

You should see readiness failures. The pods can still be running, but they won't be considered ready to receive Service traffic.

Restore `/readyz` after the experiment.

Readiness probes determine whether a pod should receive traffic. Liveness probes determine whether Kubernetes should restart a container. Startup probes allow slow-starting applications additional time before liveness checks take effect.

What we learned:
- Change configuration without rebuilding the image.
- Create a Secret without committing its value.
- Scale the Deployment and observe automatic recovery.
- Observe a readiness failure and restore the probe.
- Explain why GitOps may undo a manual change.