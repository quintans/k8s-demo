# Stage 2 — Application packaging with Kustomize

## Goal
Stop maintaining one large set of Kubernetes YAML files for every environment. Learn to share a common application definition and customize it for development, staging, and production.

Kustomize is built into kubectl, so you don't need to install another tool.

### Step 2.1 — Organize the manifests

Refactor the Kubernetes directory into this structure:
```
k8s/
├── base/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    ├── staging/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

Move your current Deployment and Service into `k8s/base/`.

Remove `namespace: demo` from the metadata of the base resources. We'll define the namespace in each environment overlay.

Also, make sure the Deployment contains the `APP_MESSAGE` ConfigMap reference from Stage 1.

### Step 2.2 — Define the common base
Create `k8s/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

configMapGenerator:
  - name: k8s-demo-config
    literals:
      - APP_MESSAGE=Hello from Kubernetes
      - LOG_LEVEL=info
```

Kustomize generates a ConfigMap with a content-derived suffix. It also rewrites references to that ConfigMap in resources it manages.

For this exercise, remove the separate `k8s/configmap.yaml` and stop creating that ConfigMap imperatively. It is now generated from the source configuration in Git.

If you want to keep the version environment variable from the CI workflow, retain it in the Deployment. The CI workflow will be improved in Stage 3.

### Step 2.3 — Create the development overlay

Create `k8s/overlays/dev/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: demo

resources:
  - ../../base

replicas:
  - name: k8s-demo
    count: 1

images:
  - name: ghcr.io/OWNER/k8s-demo
    newName: ghcr.io/OWNER/k8s-demo
    newTag: bootstrap
```

Replace `OWNER` with your lowercase GitHub username or organization.

This overlay uses one replica and a development image tag. The base Deployment must use the same image name (`ghcr.io/OWNER/k8s-demo`) for Kustomize to match it.

For a working image, set newTag to a tag that exists in GHCR. The `bootstrap` tag only works if you actually published that tag.

### Step 2.4 — Create staging and production overlays
Create `k8s/overlays/staging/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: staging

resources:
  - ../../base

replicas:
  - name: k8s-demo
    count: 2

images:
  - name: ghcr.io/OWNER/k8s-demo
    newName: ghcr.io/OWNER/k8s-demo
    newTag: bootstrap
```

Create `k8s/overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod

resources:
  - ../../base

replicas:
  - name: k8s-demo
    count: 3

images:
  - name: ghcr.io/OWNER/k8s-demo
    newName: ghcr.io/OWNER/k8s-demo
    newTag: bootstrap
```

These are configuration examples, not yet three working environments. All three overlays currently use the same tag, and your existing Argo CD application deploys only one of them.

A production overlay would normally have its own security settings, availability requirements, scaling policy, and environment-specific configuration.

### Step 2.5 — Render the manifests before deploying

Kustomize lets you see exactly what will be applied without changing the cluster.
```bash
kubectl kustomize k8s/overlays/dev
kubectl kustomize k8s/overlays/staging
kubectl kustomize k8s/overlays/prod
```

This is a powerful habit: render and inspect the desired configuration before changing live infrastructure.

Check the development replica count:
```bash
kubectl kustomize k8s/overlays/dev | grep -A 3 'replicas:'
```

You should see one replica in the rendered output.

### Step 2.6 — Connect Argo CD to the development overlay

Your existing Argo CD application currently watches the k8s directory. Change the `spec.source.path` in `argocd-application.yaml` to:
```yaml
  source:
    repoURL: https://github.com/OWNER/k8s-demo.git
    targetRevision: main
    path: k8s/overlays/dev
```

Commit the refactor and push it. Then update the Argo CD application definition:
```bash
kubectl apply -f argocd-application.yaml
```

Argo CD should now deploy the development overlay.

Check the result:
```bash
kubectl get deployment,pods,service,configmap -n demo
kubectl get application k8s-demo -n argocd
```

If you see old ConfigMaps left over from the earlier deployment, inspect the Argo CD sync status and pruning settings before deleting anything manually.

### Step 2.7 — Add persistent storage
The current API is stateless, so it doesn't need persistent storage. To learn the storage primitives, deploy a small standalone exercise.

Create `k8s/storage-demo.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage-demo
  namespace: demo
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: storage-demo
  namespace: demo
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sh", "-c", "sleep 36000"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: storage-demo
```

Apply the exercise:
```bash
kubectl apply -f k8s/storage-demo.yaml
kubectl get pvc,pod -n demo
```

The PVC should become Bound if your cluster has a working default StorageClass. Check with:
```bash
kubectl get storageclass
```

Write a file:
```bash
kubectl exec -n demo storage-demo -- \
  sh -c 'echo persistent-data > /data/example.txt'

kubectl exec -n demo storage-demo -- cat /data/example.txt
```

Delete the pod, recreate it, and read the file again:
```bash
kubectl delete pod storage-demo -n demo
kubectl apply -f k8s/storage-demo.yaml
kubectl wait --for=condition=Ready pod/storage-demo \
  -n demo --timeout=120s
kubectl exec -n demo storage-demo -- cat /data/example.txt
```

The file should remain while the PVC and its underlying volume remain intact.

Persistent storage behavior depends on the StorageClass and its backing storage. A PVC is a request for storage, not a guarantee of backup, replication, or durability. Local storage has additional limitations, especially if the node becomes unavailable. 

What we learned:
- Render all overlays with Kustomize.
- Deploy the development overlay through Argo CD.
- Change replicas without duplicating the base manifests.
- Create a PVC and observe data surviving pod replacement.
- Explain the difference between a Deployment, a Service, a ConfigMap and a PVC.