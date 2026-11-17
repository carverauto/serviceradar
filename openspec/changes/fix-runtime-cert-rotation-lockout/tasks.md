## 1. Implementation
- [x] 1.1 Generator writes the rotation record (`helm/serviceradar/files/runtime-cert-rotation.py`)
- [x] 1.2 `ComponentCertificateAuthority.record_rotated_infrastructure_successor/3`
- [x] 1.3 `ServiceRadar.Edge.RuntimeCertificateRotation`, run by the migrations hook and by core
- [x] 1.4 Mount the record (only) into core and the migrations hook
- [x] 1.5 Order the flow-collector bootstrap after recording, with a deadline
- [x] 1.6 Refuse the callout together with the root-reissuing regenerator

## 2. Validation
- [x] 2.1 Rotation-record unit test (`//helm/serviceradar:runtime_cert_rotation_test`)
- [x] 2.2 Authority and reconcile integration test
- [x] 2.3 helm-unittest for mounts, hook ordering and the regenerator guard
