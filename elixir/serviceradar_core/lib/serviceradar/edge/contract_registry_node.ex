defmodule ServiceRadar.Edge.ContractRegistryNode do
  @moduledoc """
  A core node's part in the contract registry (`ServiceRadar.Edge.ContractRegistry`).

  It owns the node's registry table, which holds the cached verified view and the latest
  installation report of each gateway, and it records this release's epoch: at boot it calls
  `ContractRegistry.ensure_local_epoch/1`, retrying with backoff until the database and the
  issuer key are available. Reads bypass the process and go straight to the table.
  """

  use GenServer

  alias ServiceRadar.Edge.ContractRegistry

  require Logger

  @initial_retry_ms 1_000
  @max_retry_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    :ets.new(ContractRegistry.cache_table(), [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    :ok = Phoenix.PubSub.subscribe(ServiceRadar.PubSub, ContractRegistry.reports_topic())
    {:ok, %{retry_ms: @initial_retry_ms}, {:continue, :ensure_epoch}}
  end

  @impl true
  def handle_continue(:ensure_epoch, state), do: {:noreply, ensure_epoch(state)}

  @impl true
  def handle_info(:ensure_epoch, state), do: {:noreply, ensure_epoch(state)}

  def handle_info({:edge_registry_gateway_report, report}, state) do
    :ok = ContractRegistry.store_gateway_report(report)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_epoch(%{retry_ms: retry_ms} = state) do
    case ContractRegistry.ensure_local_epoch() do
      {:ok, role} ->
        Logger.info("Edge contract registry: this node's catalog is #{role.role}",
          registry_epoch: role.epoch
        )

        %{state | retry_ms: @initial_retry_ms}

      {:error, reason} ->
        Logger.warning(
          "Edge contract registry epoch not recorded yet, retrying in #{retry_ms}ms: " <>
            inspect(reason),
          reason: inspect(reason)
        )

        Process.send_after(self(), :ensure_epoch, retry_ms)
        %{state | retry_ms: min(retry_ms * 2, @max_retry_ms)}
    end
  rescue
    error ->
      Logger.warning(
        "Edge contract registry epoch not recorded yet, retrying in #{retry_ms}ms: " <>
          Exception.message(error)
      )

      Process.send_after(self(), :ensure_epoch, retry_ms)
      %{state | retry_ms: min(retry_ms * 2, @max_retry_ms)}
  end
end
