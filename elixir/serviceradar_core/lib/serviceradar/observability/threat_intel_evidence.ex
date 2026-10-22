defmodule ServiceRadar.Observability.ThreatIntelEvidence do
  @moduledoc """
  Keyset pages over threat-intel inventory and historical evidence.

  These are deliberately separate from `ThreatIntelInvestigation`'s current
  matches: imported indicators and provider objects are inventory, not local
  sightings, and retrohunt findings are historical flow evidence recorded by a
  past run. Every page is one bounded query ordered by a unique key.
  """

  alias ServiceRadar.Observability.OTXRetrohuntFinding
  alias ServiceRadar.Observability.OTXRetrohuntRun
  alias ServiceRadar.Observability.ThreatIntelIndicator
  alias ServiceRadar.Observability.ThreatIntelInvestigation.Keyset
  alias ServiceRadar.Observability.ThreatIntelInvestigation.Telemetry
  alias ServiceRadar.Observability.ThreatIntelSourceObject

  require Ash.Query

  @recent_runs 10

  @doc """
  Imported indicators, newest `last_seen_at` first. Options: `:source`,
  `:indicator` (an IP returns the indicators containing it; a CIDR matches
  exactly), `:limit`, `:cursor`. Expired indicators are excluded.
  """
  @spec page_indicators(term(), keyword()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_indicators(scope, opts \\ []) do
    Telemetry.span(:imported_indicators, opts, fn -> read_indicators(scope, opts) end)
  end

  defp read_indicators(scope, opts) do
    limit = Keyset.limit(opts[:limit])
    now = DateTime.utc_now()

    with {:ok, indicator} <- indicator_filter(opts[:indicator]),
         {:ok, after_key} <- Keyset.decode(opts[:cursor], [:datetime, :uuid]) do
      ThreatIntelIndicator
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(is_nil(expires_at) or expires_at > ^now)
      |> filter_text(:source, opts[:source])
      |> filter_indicator(indicator)
      |> after_key(:last_seen_at, after_key)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(limit + 1)
      |> read_page(scope, limit, &[&1.last_seen_at, &1.id], &indicator_row/1)
    end
  end

  @doc """
  Imported provider objects (for OTX, pulses), most recently updated first.
  Options: `:source`, `:indicator` (exact indicator recorded on the object; a
  host CIDR such as `/32` also matches the bare address), `:limit`, `:cursor`.
  """
  @spec page_source_objects(term(), keyword()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_source_objects(scope, opts \\ []) do
    Telemetry.span(:source_objects, opts, fn -> read_source_objects(scope, opts) end)
  end

  defp read_source_objects(scope, opts) do
    limit = Keyset.limit(opts[:limit])

    with {:ok, after_key} <- Keyset.decode(opts[:cursor], [:datetime, :uuid]) do
      ThreatIntelSourceObject
      |> Ash.Query.for_read(:read)
      |> filter_text(:source, opts[:source])
      |> filter_object_indicator(blank_to_nil(opts[:indicator]))
      |> after_key(:updated_at, after_key)
      |> Ash.Query.sort(updated_at: :desc, id: :desc)
      |> Ash.Query.limit(limit + 1)
      |> read_page(scope, limit, &[&1.updated_at, &1.id], &source_object_row/1)
    end
  end

  @doc "The most recent retrohunt runs, newest first."
  @spec recent_retrohunt_runs(term()) :: {:ok, [map()]} | {:error, term()}
  def recent_retrohunt_runs(scope) do
    Telemetry.span(:retrohunt_runs, [], fn -> read_recent_retrohunt_runs(scope) end)
  end

  defp read_recent_retrohunt_runs(scope) do
    OTXRetrohuntRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(started_at: :desc, id: :desc)
    |> Ash.Query.limit(@recent_runs)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &run_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrohunt findings, latest evidence first. Options: `:run_id`, `:source`,
  `:observed_ip`, `:indicator` (exact CIDR), `:limit`, `:cursor`.
  """
  @spec page_retrohunt_findings(term(), keyword()) ::
          {:ok, %{rows: [map()], next_cursor: String.t() | nil}} | {:error, term()}
  def page_retrohunt_findings(scope, opts \\ []) do
    Telemetry.span(:retrohunt_findings, opts, fn -> read_retrohunt_findings(scope, opts) end)
  end

  defp read_retrohunt_findings(scope, opts) do
    limit = Keyset.limit(opts[:limit])

    with {:ok, run_id} <- optional_uuid(opts[:run_id]),
         {:ok, observed_ip} <- optional_address(opts[:observed_ip], :ip),
         {:ok, indicator} <- optional_address(opts[:indicator], :cidr),
         {:ok, after_key} <- Keyset.decode(opts[:cursor], [:datetime, :uuid]) do
      OTXRetrohuntFinding
      |> Ash.Query.for_read(:read)
      |> filter_text(:source, opts[:source])
      |> filter_finding(:run_id, run_id)
      |> filter_finding(:observed_ip, observed_ip)
      |> filter_finding(:indicator, indicator)
      |> after_key(:last_seen_at, after_key)
      |> Ash.Query.sort(last_seen_at: :desc, id: :desc)
      |> Ash.Query.limit(limit + 1)
      |> read_page(scope, limit, &[&1.last_seen_at, &1.id], &finding_row/1)
    end
  end

  defp read_page(query, scope, limit, key_fun, row_fun) do
    case Ash.read(query, scope: scope) do
      {:ok, rows} ->
        page = Keyset.page(rows, limit, key_fun)
        {:ok, %{page | rows: Enum.map(page.rows, row_fun)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp after_key(query, _field, nil), do: query

  defp after_key(query, :last_seen_at, [at, id]) do
    Ash.Query.filter(query, last_seen_at < ^at or (last_seen_at == ^at and id < ^id))
  end

  defp after_key(query, :updated_at, [at, id]) do
    Ash.Query.filter(query, updated_at < ^at or (updated_at == ^at and id < ^id))
  end

  defp filter_text(query, :source, value) do
    case blank_to_nil(value) do
      nil -> query
      text -> Ash.Query.filter(query, source == ^text)
    end
  end

  defp filter_indicator(query, nil), do: query

  defp filter_indicator(query, {:ip, ip}) do
    Ash.Query.filter(query, fragment("? >>= (?::text)::inet", indicator, ^ip))
  end

  defp filter_indicator(query, {:cidr, cidr}) do
    Ash.Query.filter(query, fragment("? = (?::text)::cidr", indicator, ^cidr))
  end

  defp filter_object_indicator(query, nil), do: query

  defp filter_object_indicator(query, indicator) do
    host = host_address(indicator)

    Ash.Query.filter(
      query,
      fragment("(?->>'indicator') IN (?::text, ?::text)", metadata, ^indicator, ^host)
    )
  end

  defp host_address(indicator) do
    with [address, prefix] <- String.split(indicator, "/", parts: 2),
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(address)),
         true <- prefix == if(tuple_size(parsed) == 4, do: "32", else: "128") do
      address
    else
      _ -> indicator
    end
  end

  defp filter_finding(query, _field, nil), do: query
  defp filter_finding(query, :run_id, run_id), do: Ash.Query.filter(query, run_id == ^run_id)

  defp filter_finding(query, :observed_ip, ip) do
    Ash.Query.filter(query, fragment("? = (?::text)::inet", observed_ip, ^ip))
  end

  defp filter_finding(query, :indicator, cidr) do
    Ash.Query.filter(query, fragment("? = (?::text)::cidr", indicator, ^cidr))
  end

  defp indicator_filter(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      text ->
        with {:ok, value} <- parse_address(text, :cidr) do
          {:ok, if(String.contains?(value, "/"), do: {:cidr, value}, else: {:ip, value})}
        end
    end
  end

  defp optional_address(value, kind) do
    case blank_to_nil(value) do
      nil -> {:ok, nil}
      text -> parse_address(text, kind)
    end
  end

  @doc """
  Validates a filter address as PostgreSQL would accept it. `:ip` takes a bare
  address (`{:error, :invalid_ip}` otherwise); `:cidr` also takes a prefix whose
  host bits are zero (`{:error, :invalid_cidr}` otherwise).
  """
  @spec parse_address(String.t(), :ip | :cidr) :: {:ok, String.t()} | {:error, atom()}
  def parse_address(text, :ip) do
    case strict_address(text) do
      {:ok, _} -> {:ok, text}
      :error -> {:error, :invalid_ip}
    end
  end

  def parse_address(text, :cidr) do
    with [address, prefix] <- String.split(text, "/", parts: 2),
         {:ok, parsed} <- strict_address(address),
         {bits, ""} <- Integer.parse(prefix),
         true <- bits in 0..max_prefix(parsed),
         true <- network_address?(parsed, bits) do
      {:ok, text}
    else
      _ -> text |> parse_address(:ip) |> host_as_cidr()
    end
  end

  # Erlang reads a zero-padded IPv4 octet as octal, which PostgreSQL rejects;
  # requiring the canonical spelling refuses it instead of reinterpreting it.
  defp strict_address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, parsed} when tuple_size(parsed) == 4 ->
        if parsed |> :inet.ntoa() |> to_string() == text, do: {:ok, parsed}, else: :error

      {:ok, parsed} ->
        {:ok, parsed}

      {:error, _} ->
        :error
    end
  end

  defp max_prefix(parsed) when tuple_size(parsed) == 4, do: 32
  defp max_prefix(_parsed), do: 128

  defp network_address?(parsed, bits) do
    total = max_prefix(parsed)
    width = div(total, tuple_size(parsed))

    value =
      parsed
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc -> Bitwise.bor(Bitwise.bsl(acc, width), part) end)

    Bitwise.band(value, Bitwise.bsl(1, total - bits) - 1) == 0
  end

  defp host_as_cidr({:ok, ip}), do: {:ok, ip}
  defp host_as_cidr(_error), do: {:error, :invalid_cidr}

  defp optional_uuid(value) do
    case blank_to_nil(value) do
      nil ->
        {:ok, nil}

      text ->
        case Ecto.UUID.cast(text) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :invalid_run_id}
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp indicator_row(row) do
    %{
      indicator_id: row.id,
      indicator: to_string(row.indicator),
      indicator_type: row.indicator_type,
      source: row.source,
      label: row.label,
      severity: row.severity,
      confidence: row.confidence,
      indicator_first_seen_at: row.first_seen_at,
      indicator_last_seen_at: row.last_seen_at,
      indicator_expires_at: row.expires_at
    }
  end

  defp source_object_row(row) do
    metadata = row.metadata || %{}

    %{
      id: row.id,
      provider: row.provider,
      source: row.source,
      object_id: row.object_id,
      object_type: row.object_type,
      label: metadata_text(metadata, "label"),
      indicator: metadata_text(metadata, "indicator"),
      date_added: row.date_added,
      modified_at: row.modified_at,
      updated_at: row.updated_at
    }
  end

  defp metadata_text(metadata, key) do
    case Map.get(metadata, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp run_row(row) do
    %{
      id: row.id,
      source: row.source,
      triggered_by: row.triggered_by,
      status: row.status,
      window_start: row.window_start,
      window_end: row.window_end,
      started_at: row.started_at,
      finished_at: row.finished_at,
      indicators_evaluated: row.indicators_evaluated,
      findings_count: row.findings_count,
      unsupported_count: row.unsupported_count,
      failed: row.status == "error"
    }
  end

  defp finding_row(row) do
    %{
      id: row.id,
      run_id: row.run_id,
      source: row.source,
      indicator: to_string(row.indicator),
      label: row.label,
      severity: row.severity,
      confidence: row.confidence,
      observed_ip: row.observed_ip |> to_string() |> String.split("/") |> hd(),
      direction: row.direction,
      first_seen_at: row.first_seen_at,
      last_seen_at: row.last_seen_at,
      evidence_count: row.evidence_count,
      bytes_total: row.bytes_total,
      packets_total: row.packets_total
    }
  end
end
