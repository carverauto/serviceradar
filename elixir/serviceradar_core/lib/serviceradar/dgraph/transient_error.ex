defmodule ServiceRadar.Dgraph.TransientError do
  @moduledoc """
  A Dgraph call that failed for a reason a later attempt can succeed at.

  `ServiceRadar.Dgraph.Call.run/3` returns `{:error, %TransientError{}}` when the
  last attempt of a call ended with kind `:timeout` (the deadline passed) or
  `:transient`: the native client found the cluster unreachable, the transport
  broken, the transaction aborted, or a Zero or Alpha group without a leader
  ("Only leader can decide to commit or abort", "No connection exists",
  "Please retry"). The classification is made once, in the native client
  (`dgraph_topology::TopologyError::from_dgraph`); every other failure stays a
  bare `{:error, String.t()}`.

  A consumer that redelivers on failure retries a record that hit one and does
  not refuse or dead-letter it for it: the EventWriter fails such an edge record
  as `ServiceRadar.EventWriter.EdgeRecordTransientError`.
  """

  defexception [:operation, :kind, :reason]

  @type t :: %__MODULE__{operation: atom(), kind: :timeout | :transient, reason: String.t()}

  @impl true
  def message(%__MODULE__{operation: operation, kind: kind, reason: reason}),
    do: "dgraph #{operation} failed (#{kind}): #{reason}"

  @doc """
  The transient Dgraph failure inside a failure reason that wraps it in tuples, as
  ingestors and projectors do (`{:plugin_result_ingest_failed, {kind, %TransientError{}}}`,
  `{%TransientError{}, provider_ref}`), or nil.
  """
  @spec find(term()) :: t() | nil
  def find(%__MODULE__{} = error), do: error

  def find(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.find_value(&find/1)

  def find(_reason), do: nil
end
