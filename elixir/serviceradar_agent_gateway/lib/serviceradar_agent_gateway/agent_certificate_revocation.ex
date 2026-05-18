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
    entry = %{
      key: key,
      revoked_at: DateTime.utc_now(),
      reason: reason
    }

    :ets.insert(state.table, {key, entry})
    Logger.warning("Agent certificate revoked: key=#{inspect(key)} reason=#{inspect(reason)}")

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
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
