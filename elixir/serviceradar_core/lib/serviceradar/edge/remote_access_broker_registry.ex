defmodule ServiceRadar.Edge.RemoteAccessBrokerRegistry do
  @moduledoc """
  Cluster-visible lookup for active remote-access broker processes.

  Browser WebSocket handlers own `RemoteAccessBroker` processes, while desktop
  WebRTC control frames arrive in core-elx. Registering brokers by session ID
  lets core-elx route low-rate keyboard, pointer, resize, and disconnect frames
  to the already-selected agent route without persisting input material.
  """

  alias ServiceRadar.ProcessRegistry

  require Logger

  @type metadata :: map()
  @registry_type :remote_access_broker

  @spec register(String.t(), metadata(), keyword()) :: :ok | {:error, term()}
  def register(session_id, metadata \\ %{}, opts \\ [])
      when is_binary(session_id) and is_map(metadata) do
    registry = Keyword.get(opts, :registry, ProcessRegistry)

    if registry_available?(registry) do
      registry_key = key(session_id)
      caller_pid = self()

      case registration_owner(registry.lookup(registry_key), caller_pid) do
        :unregistered ->
          registry_key
          |> registry.register(register_metadata(metadata, caller_pid))
          |> normalize_register_result(caller_pid)

        :owned ->
          :ok

        {:taken, owner_pid} ->
          log_registration_conflict(session_id, owner_pid, caller_pid)
          {:error, {:already_registered, owner_pid}}
      end
    else
      :ok
    end
  end

  @spec lookup(String.t(), keyword()) :: {:ok, pid(), metadata()} | {:error, term()}
  def lookup(session_id, opts \\ []) when is_binary(session_id) do
    registry = Keyword.get(opts, :registry, ProcessRegistry)

    if registry_available?(registry) do
      session_id
      |> key()
      |> registry.lookup()
      |> find_live_broker()
    else
      {:error, :broker_registry_unavailable}
    end
  end

  @spec unregister(String.t(), keyword()) :: :ok
  def unregister(session_id, opts \\ []) when is_binary(session_id) do
    registry = Keyword.get(opts, :registry, ProcessRegistry)

    if registry_available?(registry) do
      registry_key = key(session_id)

      case registration_owner(registry.lookup(registry_key), self()) do
        :owned -> registry.unregister(registry_key)
        _other -> :ok
      end
    else
      :ok
    end
  end

  defp key(session_id), do: {@registry_type, session_id}

  defp register_metadata(metadata, caller_pid) do
    metadata
    |> Map.put(:type, @registry_type)
    |> Map.put(:broker_pid, caller_pid)
    |> Map.put(:registered_at, DateTime.utc_now())
  end

  defp normalize_register_result({:ok, _pid}, _caller_pid), do: :ok

  defp normalize_register_result({:error, {:already_registered, pid}}, pid), do: :ok

  defp normalize_register_result({:error, {:already_registered, pid}}, _caller_pid),
    do: {:error, {:already_registered, pid}}

  defp normalize_register_result({:error, reason}, _caller_pid), do: {:error, reason}
  defp normalize_register_result(other, _caller_pid), do: {:error, other}

  defp registration_owner(entries, caller_pid) when is_list(entries) do
    live_entries = Enum.filter(entries, fn {pid, _metadata} -> live_pid?(pid) end)

    cond do
      owner_pid =
          Enum.find_value(live_entries, fn {pid, _metadata} -> pid != caller_pid && pid end) ->
        {:taken, owner_pid}

      Enum.any?(live_entries, fn {pid, _metadata} -> pid == caller_pid end) ->
        :owned

      true ->
        :unregistered
    end
  end

  defp registration_owner(_entries, _caller_pid), do: :unregistered

  defp find_live_broker(entries) when is_list(entries) do
    case Enum.find(entries, fn {pid, _metadata} -> live_pid?(pid) end) do
      {pid, metadata} -> {:ok, pid, metadata}
      nil -> {:error, :broker_not_found}
    end
  end

  defp find_live_broker(_other), do: {:error, :broker_not_found}

  defp live_pid?(pid), do: is_pid(pid) and Process.alive?(pid)

  defp log_registration_conflict(session_id, owner_pid, caller_pid) do
    Logger.warning("Rejected remote-access broker registry takeover",
      session_id: session_id,
      owner_pid: inspect(owner_pid),
      caller_pid: inspect(caller_pid)
    )
  end

  defp registry_available?(registry) do
    Code.ensure_loaded?(registry) and
      function_exported?(registry, :register, 2) and
      function_exported?(registry, :lookup, 1) and
      function_exported?(registry, :unregister, 1) and
      registry_process_available?(registry)
  end

  defp registry_process_available?(ProcessRegistry),
    do: Process.whereis(ProcessRegistry.registry_name()) != nil

  defp registry_process_available?(_registry), do: true
end
