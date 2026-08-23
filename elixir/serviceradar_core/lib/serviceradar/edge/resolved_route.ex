defmodule ServiceRadar.Edge.ResolvedRoute do
  @moduledoc """
  One resolved route: where a record goes, and under which versions.

  It exists so the publisher takes ONE value instead of a handful of independently-supplied
  fields. Supplying them separately let a publish name the bulk subject, fence against the
  interactive stream, and stamp provenance with a third generation, with every part individually
  valid.

  ## Opaque, and NOT a publisher input

  The type is `@opaque` and there is no public constructor: build one only through
  `ServiceRadar.Edge.StreamRoute.resolve/1`. There is no DLQ constructor -- `resolve_dlq/2` was
  removed because a DLQ route must be derived from a failure context that does not exist yet.

  Opacity alone would not be enough, because a struct is still a map at runtime and Dialyzer is
  advisory. The real protection is that `ServiceRadarAgentGateway.JetStreamPublisher` does not
  ACCEPT a route at all -- it resolves one from the same authenticated publication it is about to
  send. A forged or stale route therefore has nowhere to enter, which is a stronger guarantee than
  asking callers not to build one. Routes are returned for audit, never taken as input.

  `partition` is `nil` for a singular subject that carries no partition token -- the recovery
  lane. It is NOT `0`: zero is a real partition, and conflating "unpartitioned" with "partition
  zero" is how a singular subject quietly acquires a partitioned neighbour's semantics.

  The two versions are separate on purpose. `placement_version` moves when a partition range is
  reassigned to a different physical stream; `partition_scheme_version` moves when the subject
  families, the partition function, or the partition count change. One value could not express a
  placement change without also claiming the key space had been re-partitioned.
  """

  @enforce_keys [
    :subject,
    :partition,
    :expected_stream,
    :placement_version,
    :partition_scheme_version
  ]
  defstruct [
    :subject,
    :partition,
    :expected_stream,
    :placement_version,
    :partition_scheme_version
  ]

  @opaque t :: %__MODULE__{
            subject: String.t(),
            partition: non_neg_integer() | nil,
            expected_stream: String.t(),
            placement_version: pos_integer(),
            partition_scheme_version: pos_integer()
          }
end
