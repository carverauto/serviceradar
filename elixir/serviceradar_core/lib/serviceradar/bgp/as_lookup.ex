defmodule ServiceRadar.BGP.ASLookup do
  @moduledoc """
  AS number to organization name lookup.

  Provides mapping of AS numbers to their registered organization names.
  Results are cached to minimize external API calls.
  """

  use GenServer
  require Logger

  @cache_ttl :timer.hours(24)

  # Well-known AS mappings (for common ASes, avoids API calls)
  @well_known_as %{
    15169 => "Google LLC",
    8075 => "Microsoft Corporation",
    16509 => "Amazon.com, Inc.",
    13335 => "Cloudflare, Inc.",
    32934 => "Facebook, Inc.",
    2906 => "Netflix, Inc.",
    20940 => "Akamai International B.V.",
    714 => "Apple Inc.",
    209 => "Qwest Communications Company, LLC",
    7018 => "AT&T Services, Inc.",
    3356 => "Level 3 Parent, LLC",
    174 => "Cogent Communications",
    1299 => "Telia Company AB",
    6939 => "Hurricane Electric LLC",
    3257 => "GTT Communications Inc."
  }

  ## Client API

  @doc """
  Start the AS lookup cache server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lookup organization name for an AS number.

  Returns the organization name or "AS {number}" if lookup fails.

  ## Examples

      iex> ASLookup.lookup(15169)
      "Google LLC"

      iex> ASLookup.lookup(99999999)
      "AS 99999999"
  """
  def lookup(as_number) when is_integer(as_number) do
    # Check well-known AS first
    case Map.get(@well_known_as, as_number) do
      nil ->
        # Try cache/API lookup
        case GenServer.call(__MODULE__, {:lookup, as_number}, 10_000) do
          {:ok, name} -> name
          {:error, _} -> "AS #{as_number}"
        end

      name ->
        name
    end
  end

  def lookup(_), do: "Unknown AS"

  @doc """
  Format AS number with organization name.

  Returns formatted string like "AS 15169 (Google LLC)".

  ## Examples

      iex> ASLookup.format(15169)
      "AS 15169 (Google LLC)"
  """
  def format(as_number) when is_integer(as_number) do
    org = lookup(as_number)

    if String.starts_with?(org, "AS ") do
      org
    else
      "AS #{as_number} (#{org})"
    end
  end

  def format(_), do: "Unknown AS"

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # ETS table for caching AS lookups
    :ets.new(:as_lookup_cache, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:lookup, as_number}, _from, state) do
    now = System.system_time(:second)

    # Check cache
    case :ets.lookup(:as_lookup_cache, as_number) do
      [{^as_number, name, cached_at}] when now - cached_at < @cache_ttl ->
        {:reply, {:ok, name}, state}

      _ ->
        # Cache miss or expired - fetch from API
        case fetch_as_name(as_number) do
          {:ok, name} ->
            :ets.insert(:as_lookup_cache, {as_number, name, now})
            {:reply, {:ok, name}, state}

          {:error, reason} = error ->
            Logger.debug("AS lookup failed for #{as_number}: #{inspect(reason)}")
            {:reply, error, state}
        end
    end
  end

  ## Private Functions

  # Fetch AS name from Team Cymru whois service
  defp fetch_as_name(as_number) do
    # Use DNS-based whois (Team Cymru)
    # Query: AS{number}.asn.cymru.com TXT
    query = "AS#{as_number}.asn.cymru.com"

    case :inet_res.lookup(String.to_charlist(query), :in, :txt) do
      [] ->
        {:error, :not_found}

      results ->
        # Parse TXT record: "AS | CC | Registry | Allocated | AS Name"
        case parse_cymru_result(results) do
          {:ok, name} -> {:ok, name}
          :error -> {:error, :parse_failed}
        end
    end
  rescue
    e ->
      {:error, {:exception, e}}
  end

  # Parse Team Cymru TXT record result
  defp parse_cymru_result([txt_record | _]) when is_list(txt_record) do
    # TXT record is a list of charlists, join them
    result =
      txt_record
      |> Enum.map(&to_string/1)
      |> Enum.join()

    # Format: "15169 | US | arin | 2000-03-30 | GOOGLE, US"
    case String.split(result, "|") do
      [_as, _cc, _registry, _date, name] ->
        {:ok, String.trim(name)}

      _ ->
        :error
    end
  end

  defp parse_cymru_result(_), do: :error
end
