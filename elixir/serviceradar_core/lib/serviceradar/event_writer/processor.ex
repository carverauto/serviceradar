defmodule ServiceRadar.EventWriter.Processor do
  @moduledoc """
  Behaviour for EventWriter message processors.

  Each processor handles a specific type of message from NATS JetStream
  and writes it to the appropriate CNPG hypertable.

  ## Implementing a Processor

      defmodule MyApp.Processors.Telemetry do
        @behaviour ServiceRadar.EventWriter.Processor

        @impl true
        def process_batch(messages) do
          rows = Enum.map(messages, &parse_message/1)

          case MyApp.Repo.insert_all("timeseries_metrics", rows, on_conflict: :nothing) do
            {count, _} -> {:ok, count}
          end
        rescue
          e -> {:error, e}
        end

        @impl true
        def table_name, do: "timeseries_metrics"
      end
  """

  @doc """
  Processes a batch of Broadway messages.

  Returns `{:ok, count}` on success where count is the number of rows inserted,
  or `{:error, reason}` on failure.
  """
  @callback process_batch([Broadway.Message.t()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Returns the target table name for this processor.
  """
  @callback table_name() :: String.t()

  @doc """
  Parses a single message payload into a row map for insertion.

  This is an optional callback - processors can implement their own parsing
  logic directly in `process_batch/1` if needed.
  """
  @callback parse_message(Broadway.Message.t()) :: map() | nil

  @optional_callbacks [parse_message: 1]
end
