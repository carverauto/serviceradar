# Recording control primitives

`serviceradar_recording_control` owns the read-only deployment recovery gate
shared by Core and NVR. It depends on the metadata codec and Ecto UUID casting,
with no Core, database adapter or media-library dependency. It starts no service,
worker, listener or repository and never creates or changes recovery state.

Consumers pin configuration at boot and check the shared gate at their admission
and reply boundaries. The file contract and operator requirements are documented
in [the NVR runtime runbook](../../docs/nvr-runtime.md#deployment-recovery-gate).
A ready gate does not grant current-history approval, storage qualification,
playback access or physical source retirement.

The packaged NVR release suite owns the file contract and live-state checks.
`RecoveryGate.with_ready/2` owns the before/after success checks shared by Core's
publication, recording-admission, upload-lease, archive-authority and archive-reader consumers. Each consumer
rejects ambient transactions and owns its database work.
Core's recording-block integration suite owns receipt persistence and closure
across acceptance and upload lease acquisition/renewal, and its recorder-ownership integration suite owns new-work
admission closure. Core's archive-upload integration suite owns recovery closure
during authority issuance, application, publication and archive reads; web-ng's publication DB suite owns the authenticated HTTP
response and retry behavior, and its media-upload DB suite owns provider-grant
and post-fetch recovery closure. The library's format and Credo checks run through
`//build/elixir_quality:quality_check`.
