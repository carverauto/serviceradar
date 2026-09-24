defmodule ServiceRadar.Edge.ProjectionTime do
  @moduledoc """
  Elixir peer of Go's `projection.CanonicalMicros` (task 1.5-c).

  Names the microsecond bucket CONTAINING an instant: `u * 1000 <= ns < (u + 1) * 1000`. That
  inequality is mathematical -- near the extremes of a 64-bit range both bounds exceed it, so
  it is reasoned about rather than evaluated.

  ## Where this may be used, and where it may not

  ONLY for projection-domain STORAGE AND ORDERING COORDINATES. It SHALL NOT be applied before
  either contract hash: `payload_sha256` covers the exact carried payload bytes, and
  `semantic_envelope_sha256` covers a field-framed transcript committing `payload_sha256` and
  the RAW nanosecond values. Canonicalizing before either would make contract identity depend
  on a normalization step rather than on what was received.

  It is also NOT applied to the AGE graph's `(observed_at, trace_id)` ordering, which stays in
  raw nanoseconds because the graph is not bound by `timestamptz` resolution -- canonicalizing
  there would collapse sub-microsecond observations into ties broken arbitrarily by trace id.

  ## Floor, not truncation toward zero

  The reason is the containing-bucket invariant, NOT monotonicity -- both are monotonic, so
  monotonicity cannot distinguish them. Truncation satisfies the invariant only for
  non-negative inputs: `-1500` truncates to `-1`, whose bucket `[-1000, 0)` does not contain
  `-1500`. Floor gives `-2`, spanning `[-2000, -1000)`, which does.

  ## Why this is not simply `div/2`

  Elixir integers are arbitrary precision, so the overflow that broke the Go implementation
  cannot occur here -- but `div/2` truncates toward zero, so it is wrong for negatives for the
  reason above. `Integer.floor_div/2` is the correct primitive, and the shared vectors hold
  both runtimes to the same table regardless of which primitive each uses.
  """

  @nanos_per_micro 1000

  @doc """
  Returns the microsecond bucket containing `unix_nanos`.
  """
  @spec canonical_micros(integer()) :: integer()
  def canonical_micros(unix_nanos) when is_integer(unix_nanos) do
    Integer.floor_div(unix_nanos, @nanos_per_micro)
  end
end
