# gitops-platform-kind

A small, runnable version of how I run Kubernetes with GitOps: **Argo CD app-of-apps**, platform
components installed in **sync waves**, and services defined once in a **Kustomize base** with thin
per-environment overlays. Everything runs locally on [kind](https://kind.sigs.k8s.io/).

```
bootstrap/
  kind-config.yaml        1 control plane + 2 workers, ports 80/443 mapped for ingress
  argocd-cm-patch.yaml    health check so app-of-apps sync waves really wait
  up.sh                   create cluster -> install Argo CD -> apply root app
argocd/
  root.yaml               the only thing applied by hand
  apps/
    ingress-nginx.yaml          wave 0
    kube-prometheus-stack.yaml  wave 1  (CRDs for PodMonitor/PrometheusRule)
    cloudnative-pg.yaml         wave 1  (Postgres operator)
    postgres.yaml               wave 2  (the database itself; manual sync on purpose)
    services.yaml               wave 3  ApplicationSet: one app per apps/overlays/<env>/<service>
platform/postgres/        CNPG cluster (1 primary + 2 replicas) + alerts
apps/
  base/podinfo/           the service, defined once, with its safety kit
  overlays/dev/podinfo/       namespace, replicas 1, host, message
  overlays/staging/podinfo/   namespace, host, message
```

## Run it

Needs Docker, kind, kubectl. Fork the repo and change `repoURL` in `argocd/` if you want to push changes.

```bash
./bootstrap/up.sh
kubectl -n argocd get applications -w     # watch the waves go green
curl http://podinfo-dev.localtest.me
kind delete cluster --name gitops-demo    # clean up
```

## The per-service safety kit

Every service in `apps/base/<svc>/` ships with the same set, so nothing reaches an environment without it:

| File | What it does | Why |
|---|---|---|
| `deployment.yaml` | `maxSurge 1 / maxUnavailable 0`, readiness gates traffic, non-root, read-only root FS, all capabilities dropped | Releases never drop capacity; a broken build never gets traffic; a compromised container can't do much |
| `service.yaml` | app port + metrics port declared | Policies and scrapers can only target ports they can see |
| `networkpolicy.yaml` | default deny, then allow ingress controller → app port, Prometheus → metrics port, pod → DNS | A pod can talk to exactly what it needs, nothing else |
| `pdb.yaml` | at most one pod evicted at a time | Node drains and upgrades can't take the service down |
| `monitoring.yaml` | PodMonitor + PrometheusRule (down / error rate / restart loop) | Monitoring is added with the service, not remembered later |
| `ingress.yaml` | host routing | Overlays only change the host |

## Things this repo gets right that are easy to get wrong

1. **App-of-apps sync waves don't wait by default.** Argo CD stopped assessing child `Application` health
   in 1.8, so wave 3 starts while wave 1 is still installing CRDs and the first sync fails.
   `bootstrap/argocd-cm-patch.yaml` restores the health check.
2. **kube-prometheus-stack ignores your PodMonitors and rules.** Out of the box it only selects objects
   labelled with its own Helm release. Every per-service rule is created, valid, and never loaded, so no
   alert can fire. The `*SelectorNilUsesHelmValues: false` settings fix it.
3. **Large CRDs need Server-Side Apply.** kube-prometheus-stack and Argo CD's own CRDs exceed the 256 KB
   `last-applied-configuration` annotation; client-side apply fails.
4. **Stateful apps are not auto-synced or auto-pruned.** A bad commit to `platform/postgres` should not be
   able to delete a database. The `postgres` app is synced on purpose.
5. **Alert on the silent stage.** `PostgresWalArchivingFailing` and `PostgresVolumeAlmostFull` fire hours
   before "database down" would: a broken WAL archiver looks healthy while WAL fills the primary's disk.
6. **No duplicate PDB for Postgres.** CNPG creates its own; a second overlapping one can block drains.

## Releasing

CI builds an image and commits the new tag to `apps/overlays/<env>/<svc>/kustomization.yaml`. Argo CD
rolls it out. Rollback is `git revert`.

## Left out to keep kind small

On a real cluster I'd add Istio with STRICT mTLS (metrics port left PERMISSIVE for Prometheus), Vault with
the Vault Secrets Operator for short-lived database credentials, and cert-manager. See
[gke-platform-terraform](https://github.com/Charbelm123/gke-platform-terraform) for the cluster underneath.
