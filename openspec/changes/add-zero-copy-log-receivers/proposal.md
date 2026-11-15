# Change: Support portable and accelerated log receive paths

Status: approved for implementation and bounded hardware experiments.

## Why

High-volume collectors should exploit efficient receive mechanisms while
remaining deployable on Kubernetes workers, bare metal and VMs. Guest/pod
interfaces do not necessarily expose the host NIC's acceleration.

## What Changes

- Keep efficient conventional UDP/TCP as a supported production path.
- Compare recvmmsg, async TCP and ordinary io_uring with identical processing.
- Add optional AF_XDP UDP and io_uring ZC Rx TCP backends with real capability
  checks, explicit selection and observable automatic fallback.
- Define buffer leases across parsing and Zen, recycling before publish ACK.
- Define Kubernetes device, capability and seccomp requirements per backend.

## Impact

Changes receiver/framing ownership, bounded worker handoff and deployment
configuration. AF_XDP is not a replacement TCP stack. No global privilege
relaxation, mandatory accelerator hardware, or end-to-end zero-copy claim.
