# Change: Harden demo Kubernetes control-plane exposure and SPIRE mounts

## Why
The default `k8s/demo` deployment path still mounts host SPIRE sockets into workloads even though SPIRE is documented as optional, and the prod/staging overlays publish datasvc externally through `LoadBalancer` services by default. Those defaults widen the demo trust boundary in ways that are unnecessary for the default install path.

## What Changes
- remove default host SPIRE socket mounts and SPIRE-specific workload env wiring from the non-SPIRE demo base
- keep SPIRE-specific mounts and wiring behind an explicit opt-in path
- remove datasvc external `LoadBalancer` services from the default prod/staging overlays
- document any future external datasvc exposure as explicit operator opt-in only

## Impact
- Affected specs: `edge-architecture`
- Affected code: `k8s/demo/base/*.yaml`, `k8s/demo/prod/*.yaml`, `k8s/demo/staging/*.yaml`, `k8s/demo/README.md`
