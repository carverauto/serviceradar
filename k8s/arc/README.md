# ARC runner notes

We hit missing host tools (cmake, flex, protoc, perl/OpenSSL) when publishing images on the GitHub Actions ARC runners. Use a custom runner image with the needed packages and point the scale set at it.

## Build/push runner image

Use Bazel to build/push the runner so it stays aligned with the rest of the
image pipeline:

```
bazel run //docker/images:arc_runner_image_amd64_push
```

## Helm install override (gha-runner-scale-set)

Pass a small values override that pins the runner image; for example:

```yaml
runnerScaleSetName: serviceradar
githubConfigUrl: <REPO_URL>
githubConfigSecret:
  github_token: <PAT>
template:
  spec:
    containers:
    - name: runner
      image: ghcr.io/carverauto/arc-runner:latest
```

Then install with:

```
helm install <name> \
  --namespace <ns> \
  --create-namespace \
  -f ./k8s/arc/values.yaml \
  -f ./k8s/arc/runner-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

Adjust secrets/labels as needed; the key is ensuring the runner image has the tooling above so Bazel `genrule` work that must run locally can succeed.
