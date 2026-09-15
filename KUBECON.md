# KubeCon.AI Staging Deployment

Branch use to stage new development


## Helm Kata-Container deployment on K3S

```sh
cd tools/packaging/kata-deploy/helm-chart/kata-deploy
helm upgrade --install kata-deploy \
  --namespace kube-system \
  ./kata-deploy \
  -f values-k3s.yaml
```