defmodule ServiceRadarAgentGateway.AgentCertificateRevocation do
  @moduledoc """
  In-memory revocation denylist for agent mTLS certificates.

  This is the immediate kill switch for compromised edge certificates. It is
  intentionally local to the agent-gateway process today; CRL/OCSP or durable
  cluster-wide storage can replace the backend without changing callers.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @type revocation_entry :: %{
          key: tuple(),
          revoked_at: DateTime.t(),
          reason: String.t() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec revoke_component_id(String.t(), keyword()) :: :ok
  def revoke_component_id(component_id, opts \\ []) when is_binary(component_id) do
    revoke({:component_id, component_id}, opts)
  end

  @spec revoke_fingerprint(String.t(), keyword()) :: :ok
  def revoke_fingerprint(fingerprint, opts \\ []) when is_binary(fingerprint) do
    revoke({:fingerprint, normalize_fingerprint(fingerprint)}, opts)
  end

  @spec revoke_serial_number(integer(), keyword()) :: :ok
  def revoke_serial_number(serial_number, opts \\ []) when is_integer(serial_number) do
    revoke({:serial_number, serial_number}, opts)
  end

  @doc """
  Registers a pending certificate renewal handoff from `predecessor` to `successor`
  for `component_id`.

  The predecessor certificate is NOT revoked at issuance time so that a lost
  `RenewCertificate` response or mid-write crash cannot strand the agent. The
  predecessor is retired only when `confirm_successor_hello/1` observes `successor`
  during an authenticated `Hello`.
  """
  @spec register_pending_renewal(String.t(), map(), map()) :: :ok
  def register_pending_renewal(component_id, predecessor, successor)
      when is_binary(component_id) and is_map(predecessor) and is_map(successor) do
    GenServer.call(__MODULE__, {:register_pending_renewal, component_id, predecessor, successor})
  end

  @doc """
  Confirms a pending renewal handoff when an agent completes `Hello` presenting
  the successor certificate, immediately revoking the predecessor certificate
  with `reason = "superseded_by_renewal"`.
  """
  @spec confirm_successor_hello(map()) :: {:ok, map()}
  def confirm_successor_hello(identity) when is_map(identity) do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, %{superseded: false}}
      _pid -> GenServer.call(__MODULE__, {:confirm_successor_hello, identity})
    end
  end

  def confirm_successor_hello(_identity), do: {:ok, %{superseded: false}}

  @spec clear :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @spec revoked?(map()) :: boolean()
  def revoked?(identity) when is_map(identity) do
    identity
    |> revocation_keys()
    |> Enum.any?(&revoked_key?/1)
  end

  def revoked?(_identity), do: false

  @spec revoked_reason(map()) :: String.t() | nil
  def revoked_reason(identity) when is_map(identity) do
    identity
    |> revocation_keys()
    |> Enum.find_value(fn key ->
      case lookup(key) do
        nil -> nil
        entry -> Map.get(entry, :reason)
      end
    end)
  end

  def revoked_reason(_identity), do: nil

  defp revoke(key, opts) do
    reason =
      opts
      |> Keyword.get(:reason)
      |> normalize_reason()

    GenServer.call(__MODULE__, {:revoke, key, reason})
  end

  @impl true
  def handle_call({:revoke, key, reason}, _from, state) do
    insert_revocation(state.table, key, reason)
    {:reply, :ok, state}
  end

  def handle_call({:register_pending_renewal, component_id, predecessor, successor}, _from, state) do
    pred_fp = extract_fingerprint(predecessor)
    pred_serial = extract_serial_number(predecessor)
    succ_fp = extract_fingerprint(successor)
    succ_serial = extract_serial_number(successor)

    entry = %{
      component_id: component_id,
      predecessor_fingerprint: pred_fp,
      predecessor_serial_number: pred_serial,
      successor_fingerprint: succ_fp,
      successor_serial_number: succ_serial,
      registered_at: DateTime.utc_now()
    }

    if is_binary(succ_fp) and succ_fp != "" do
      :ets.insert(state.table, {{:pending_renewal, component_id, {:fingerprint, succ_fp}}, entry})
    end

    {:reply, :ok, state}
  end

  def handle_call({:confirm_successor_hello, identity}, _from, state) do
    component_id = Map.get(identity, :component_id)
    succ_fp = extract_fingerprint(identity)

    pending =
      find_pending_renewal(state.table, component_id, succ_fp)

    case pending do
      nil ->
        {:reply, {:ok, %{superseded: false}}, state}

      entry ->
        retire_predecessor(state.table, entry, succ_fp)
        delete_pending_renewals_for_predecessor(state.table, component_id, entry)

        {:reply,
         {:ok,
          %{
            superseded: true,
            predecessor_fingerprint: entry.predecessor_fingerprint,
            predecessor_serial_number: entry.predecessor_serial_number
          }}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  defp insert_revocation(table, key, reason) do
    entry = %{
      key: key,
      revoked_at: DateTime.utc_now(),
      reason: reason
    }

    :ets.insert(table, {key, entry})
    Logger.warning("Agent certificate revoked: key=#{inspect(key)} reason=#{inspect(reason)}")
  end

  defp find_pending_renewal(table, component_id, succ_fp)
       when is_binary(component_id) and is_binary(succ_fp) and succ_fp != "" do
    key = {:pending_renewal, component_id, {:fingerprint, succ_fp}}

    case :ets.lookup(table, key) do
      [{^key, entry}] -> entry
      [] -> nil
    end
  end

  defp find_pending_renewal(_table, _component_id, _succ_fp), do: nil

  defp retire_predecessor(table, entry, succ_fp) do
    reason = "superseded_by_renewal"

    if is_binary(entry.predecessor_fingerprint) and entry.predecessor_fingerprint != "" and
         entry.predecessor_fingerprint != succ_fp do
      insert_revocation(table, {:fingerprint, entry.predecessor_fingerprint}, reason)
    end
  end

  defp delete_pending_renewals_for_predecessor(table, component_id, target_entry) do
    table
    |> :ets.match_object({{:pending_renewal, component_id, :_}, :_})
    |> Enum.each(fn {key, entry} ->
      if entry.predecessor_fingerprint == target_entry.predecessor_fingerprint and
           entry.predecessor_serial_number == target_entry.predecessor_serial_number do
        :ets.delete(table, key)
      end
    end)

    :ok
  end

  defp extract_fingerprint(map) when is_map(map) do
    normalize_fingerprint(
      Map.get(map, :certificate_fingerprint) || Map.get(map, :cert_fingerprint_sha256) || Map.get(map, :fingerprint)
    )
  end

  defp extract_serial_number(map) when is_map(map) do
    case Map.get(map, :serial_number) || Map.get(map, :serial_number_int) do
      serial when is_integer(serial) and serial > 0 ->
        serial

      serial when is_binary(serial) ->
        case Integer.parse(String.trim(serial), 16) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp revoked_key?(key), do: not is_nil(lookup(key))

  defp lookup(key) do
    case :ets.info(@table) do
      :undefined ->
        nil

      _info ->
        case :ets.lookup(@table, key) do
          [{^key, entry}] -> entry
          [] -> nil
        end
    end
  rescue
    ArgumentError -> nil
  end

  defp revocation_keys(identity) do
    Enum.reject(
      [
        identity |> Map.get(:component_id) |> key_if_present(:component_id),
        identity |> Map.get(:certificate_fingerprint) |> normalize_fingerprint() |> key_if_present(:fingerprint),
        identity |> Map.get(:serial_number) |> key_if_integer(:serial_number)
      ],
      &is_nil/1
    )
  end

  defp key_if_present(nil, _type), do: nil
  defp key_if_present("", _type), do: nil
  defp key_if_present(value, type) when is_binary(value), do: {type, value}
  defp key_if_present(_value, _type), do: nil

  defp key_if_integer(value, type) when is_integer(value), do: {type, value}
  defp key_if_integer(_value, _type), do: nil

  defp normalize_fingerprint(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_fingerprint(_value), do: nil

  defp normalize_reason(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: String.slice(value, 0, 256)
  end

  defp normalize_reason(_value), do: nil
end
