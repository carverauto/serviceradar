defmodule ServiceRadar.Edge.ResolvedRoute do
  @moduledoc """
  One immutable resolved route: where a record goes, and under which route-map generation.

  It exists so the publisher takes ONE value instead of a handful of independently-supplied
  fields. The previous shape let a caller pass a subject, an expected stream, and a route-map
  version that had nothing to do with each other -- a publish could name the bulk subject, fence
  against the interactive stream, and stamp provenance with a third generation, and every part
  looked individually valid. Bundling them means they are computed together or not at all.

  Construct these ONLY through `ServiceRadar.Edge.StreamRoute.resolve/1` and `resolve_dlq/2`.
  The struct is deliberately free of a public constructor beyond that: a hand-built
  `%ResolvedRoute{}` would reintroduce exactly the incoherence it exists to prevent.

  `partition` is `nil` for a singular subject that carries no partition token -- the recovery
  lane. It is NOT `0`: zero is a real partition, and conflating "unpartitioned" with "partition
  zero" is how a singular subject quietly acquires a partitioned neighbour's semantics.
  """

  @enforce_keys [:subject, :partition, :expected_stream, :map_version]
  defstruct [:subject, :partition, :expected_stream, :map_version]

  @type t :: %__MODULE__{
          subject: String.t(),
          partition: non_neg_integer() | nil,
          expected_stream: String.t(),
          map_version: pos_integer()
        }
end
