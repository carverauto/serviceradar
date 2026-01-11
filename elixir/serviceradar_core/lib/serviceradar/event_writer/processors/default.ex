defmodule ServiceRadar.EventWriter.Processors.Default do
  @moduledoc """
  Default processor for unrecognized message types.

  Logs unhandled messages for debugging and returns success
  to avoid blocking the pipeline.
  """

  @behaviour ServiceRadar.EventWriter.Processor

  require Logger

  @impl true
  def table_name, do: "unknown"

  @impl true
  def process_batch(messages) do
    count = length(messages)

    if count > 0 do
      Logger.warning("Default processor received #{count} unhandled messages",
        sample_subject: hd(messages).metadata[:subject]
      )
    end

    # Return success to acknowledge messages (don't block pipeline)
    {:ok, 0}
  end
end
