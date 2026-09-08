defmodule ServiceRadar.EventWriter.Processors.Default do
  @moduledoc """
  Default processor for unrecognized message types.

  Logs unhandled messages for debugging and returns success
  to avoid blocking the pipeline.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @expected_ignored_subjects MapSet.new([
                               "logs.syslog",
                               "logs.snmp",
                               "logs.otel",
                               "events.syslog",
                               "events.snmp",
                               "snmp.traps"
                             ])

  @impl true
  def table_name, do: "unknown"

  @impl true
  def process_batch(messages) do
    count = length(messages)

    if count > 0 do
      top_subjects =
        messages
        |> Enum.map(&(&1.metadata[:subject] || "<nil>"))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_subject, c} -> -c end)
        |> Enum.take(3)
        |> Enum.map_join(", ", fn {subject, c} -> "#{subject}=#{c}" end)

      subjects =
        messages
        |> Enum.map(& &1.metadata[:subject])
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      if map_size(subjects) > 0 and MapSet.subset?(subjects, @expected_ignored_subjects) do
        Logger.debug(
          "Default processor skipped expected subjects (top subjects: #{top_subjects})"
        )
      else
        Logger.warning(
          "Default processor received #{count} unhandled messages (top subjects: #{top_subjects})"
        )
      end
    end

    # Return success to acknowledge messages (don't block pipeline)
    {:ok, 0}
  end
end
