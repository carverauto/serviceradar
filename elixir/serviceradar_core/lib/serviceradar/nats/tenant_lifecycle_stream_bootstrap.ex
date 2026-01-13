defmodule ServiceRadar.NATS.TenantLifecycleStreamBootstrap do
  @moduledoc """
  Ensures the tenant lifecycle JetStream stream exists for provisioning events.
  """

  use GenServer

  require Logger

  alias Jetstream.API.Stream
  alias ServiceRadar.Identity.TenantLifecyclePublisher
  alias ServiceRadar.NATS.Connection

  @retry_delay 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :ensure_stream, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:ensure_stream, state) do
    case ensure_stream() do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[NATS Bootstrap] Tenant lifecycle stream not ready",
          reason: inspect(reason)
        )

        Process.send_after(self(), :ensure_stream, @retry_delay)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Ensure the tenant lifecycle JetStream stream exists.
  """
  @spec ensure_stream() :: :ok | {:error, term()}
  def ensure_stream do
    case Connection.get() do
      {:ok, conn} ->
        ensure_stream(conn)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_stream(conn) do
    stream_name = TenantLifecyclePublisher.stream_name()
    subject = TenantLifecyclePublisher.subject_pattern()

    case Stream.info(conn, stream_name) do
      {:ok, %{config: %Stream{subjects: subjects} = config}} ->
        if subject in subjects do
          :ok
        else
          update_subjects(conn, config, subject, stream_name)
        end

      {:error, %{"code" => 404}} ->
        create_stream(conn, stream_name, subject)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_stream(conn, stream_name, subject) do
    stream = %Stream{
      name: stream_name,
      subjects: [subject],
      retention: :limits,
      storage: :file
    }

    case Stream.create(conn, stream) do
      {:ok, _info} ->
        Logger.info("[NATS Bootstrap] Tenant lifecycle stream created", stream: stream_name)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_subjects(conn, %Stream{} = config, subject, stream_name) do
    updated = %{config | subjects: Enum.uniq(config.subjects ++ [subject])}

    case Stream.update(conn, updated) do
      {:ok, _info} ->
        Logger.info("[NATS Bootstrap] Tenant lifecycle stream updated", stream: stream_name)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
