defmodule ServiceRadar.EventWriter.EdgeRecordRefusedError do
  @moduledoc """
  The failure of an edge record that `ServiceRadar.EventWriter.Processors.EdgeRecord.ingest/4`
  refused: a header, slot, wire or contract check failed, its grant or assignment is no longer
  current, its delivery slot or event id is bound to other bytes, or its projector refused it.
  `reason` is the refusal `ingest/4` returned.

  The same bytes are refused again on every redelivery, so the pipeline dead-letters the record
  on its first delivery (`ServiceRadar.EventWriter.EdgeRecordDeadLetter.terminal?/1`), where it
  stays for inspection and for replay once its cause is fixed.
  """

  defexception [:reason]

  @impl true
  def message(%__MODULE__{reason: reason}),
    do: "edge record refused: #{inspect(reason, limit: 8, printable_limit: 128)}"
end
