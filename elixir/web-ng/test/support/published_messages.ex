defmodule ServiceRadarWebNG.TestSupport.PublishedMessages do
  @moduledoc """
  Stands in for the acknowledged JetStream publisher of internal telemetry
  (`:internal_telemetry_publisher`) and forwards each message to the test
  process that called `capture/0`, so a test reads an audit record exactly as
  EventWriter would store it.

  The publisher is application-wide, so only `async: false` tests may use it.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  @receiver :web_ng_test_published_messages

  @doc false
  def publish(subject, body, _opts) do
    case Process.whereis(@receiver) do
      nil -> :ok
      pid -> send(pid, {:published, subject, body})
    end

    :ok
  end

  @doc "Routes internal telemetry publishes to the calling test process until it exits."
  def capture do
    previous = Application.get_env(:serviceradar_core, :internal_telemetry_publisher)
    Process.register(self(), @receiver)
    Application.put_env(:serviceradar_core, :internal_telemetry_publisher, __MODULE__)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :internal_telemetry_publisher)
      else
        Application.put_env(:serviceradar_core, :internal_telemetry_publisher, previous)
      end
    end)
  end

  @doc "Waits for the audit record published for `resource_id` and returns it decoded."
  def receive_audit_record(resource_id) do
    receive do
      {:published, subject, body} ->
        record = Jason.decode!(body)

        if String.ends_with?(subject, "logs.internal.audit") and
             get_in(record, ["unmapped", "resource_id"]) == resource_id do
          record
        else
          receive_audit_record(resource_id)
        end
    after
      5_000 -> flunk("no audit record was published for #{resource_id}")
    end
  end
end
