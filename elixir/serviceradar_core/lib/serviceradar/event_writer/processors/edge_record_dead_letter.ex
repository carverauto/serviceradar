defmodule ServiceRadar.EventWriter.Processors.EdgeRecordDeadLetter do
  @moduledoc """
  Consumes the edge-record dead-letter stream
  (`ServiceRadar.EventWriter.Config.edge_record_dead_letter_stream/0`) and writes nothing.

  EventWriter provisions every stream it owns together with a durable, so the dead-letter
  stream has one too, and the consumer-state poll reports the stream's depth through it. The
  record was already reported when it was dead-lettered
  (`ServiceRadar.EventWriter.EdgeRecordDeadLetter`): a log line naming the dead-letter stream
  sequence and a counter by contract and reason. Acknowledging a message here does not remove
  it, because the stream keeps it under limits retention with `MaxAge` disabled. Only a replay
  or an operator deletes it.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  @impl true
  def table_name, do: "edge_record_dead_letter"

  @impl true
  def process_batch(_messages), do: {:ok, 0}
end
