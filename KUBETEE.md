# C3K.AI Staging Deployment

Branch use to stage new development

## Helm Kata-Container deployment on K3S

```sh
helm upgrade --install kata-deploy \
  --namespace kube-system \
  tools/packaging/kata-deploy/helm-chart/kata-deploy \
  -f ./tools/packaging/kata-deploy/helm-chart/kata-deploy/values-k3s.yaml
```
