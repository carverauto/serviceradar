# Member storage identity configuration

Core resolves the expected recording-storage UUID once, while evaluating its
release runtime configuration. This step selects identity only: it does not
create a directory, read or write a marker, start a recorder or enable capture.
Storage.open/2 still verifies the configured spool against the selected UUID.

## Configuration modes

- Scalar mode: leave SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE and
  SERVICERADAR_CAMERA_RECORDING_MEMBER unset. The existing
  SERVICERADAR_CAMERA_RECORDING_STORAGE_ID passes through unchanged; its absence
  remains nil, and storage validation still owns scalar UUID validation.
- Member mode: set SERVICERADAR_CAMERA_RECORDING_IDENTITY_FILE to the installed
  document path and SERVICERADAR_CAMERA_RECORDING_MEMBER to the exact member key.
  Leave SERVICERADAR_CAMERA_RECORDING_STORAGE_ID unset.

Both document settings are required together. Setting the scalar and document
sources together is an error even if their UUIDs agree. Empty strings are
explicit configuration, not an unset value. Member mode has no HOSTNAME,
ordinal-derived UUID, scalar fallback or marker-adoption fallback.

An invalid member-mode configuration raises a bounded startup error, including
when recording is disabled. The error identifies the failure class without
printing document contents or the path. A valid mapping does not attest the
mounted PVC/PV/CSI association; installation preflight must verify that separately.

## Version 1 document

This entirely synthetic example describes two independent storage lifetimes:

```json
{
  "version": 1,
  "members": {
    "camera-core-0": "00000000-0000-4000-8000-000000000011",
    "camera-core-1": "00000000-0000-4000-8000-000000000012"
  }
}
```

The contract is:

- Exactly the top-level fields version and members, with integer version 1.
- One through 256 members and at most 65,536 bytes, including whitespace.
- Each key is 1 through 253 ASCII bytes, starts and ends with a lowercase
  letter or digit, and otherwise contains lowercase letters, digits, dots or
  hyphens. Keys are exact installation identifiers, not paths.
- Each value is a canonical lowercase, hyphenated UUID. Every member must have
  a distinct UUID, and the selected member must be present.
- Duplicate keys at any level, arrays, unknown fields, malformed JSON, invalid
  unselected members and unsupported versions are refused.

The path must resolve to a regular file. Symlinks to regular files are supported
for Kubernetes projected configuration. Reads are capped at the byte budget plus
one byte to detect overflow. The installation controller owns the file and its
directory; this is not a user-uploaded document path. The document contains no
credentials. A projected-file update takes effect on the next core start, not
through a background reload.

## Remaining installation work

Infrastructure must allocate each UUID independently, preserve its association
with the actual volume lifetime, and install the document. Changing a member's
mapping is not authorization to initialize, replace or adopt a volume.

The [explicit filesystem initializer](../../../docs/camera-spool-initialization.md)
uses the same identity modes. See the [implementation tasks](tasks.md) for the
status of volume preflight, packaging, conversion, Cloud materialization and
deployment acceptance. Existing filesystem and worker ownership checks remain
mandatory.
