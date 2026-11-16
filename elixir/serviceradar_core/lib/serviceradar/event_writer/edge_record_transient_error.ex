defmodule ServiceRadar.EventWriter.EdgeRecordTransientError do
  @moduledoc """
  The failure of an edge record that `ServiceRadar.EventWriter.Processors.EdgeRecord.ingest/4`
  could not take for a reason that is not the record's fault, so a later delivery can succeed
  with the same bytes: a decode `ServiceRadar.Edge.WireDecode.transient?/1` reports as transient
  (a schema not deployed yet, a decoder fault), or a projector side effect that failed with a
  `ServiceRadar.Dgraph.TransientError` (a Dgraph timeout or leader election). `reason` is the
  reason `ingest/4` or the projector returned.

  Unlike a refusal (`ServiceRadar.EventWriter.EdgeRecordRefusedError`) it is not dead-lettered on
  its first delivery: JetStream redelivers it with backoff and it is dead-lettered only at the
  stream's threshold (`ServiceRadar.EventWriter.EdgeRecordDeadLetter`). Until then the pipeline
  logs it as a rate-limited warning, not an error; the dead-letter is logged as an error.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "edge record not taken yet: #{inspect(reason, limit: 8, printable_limit: 128)}"
end
