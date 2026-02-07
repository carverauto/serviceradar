defmodule ServiceRadar.Observability.IpEnrichmentRefreshWorker do
  @moduledoc """
  Background job that refreshes IP enrichment caches (rDNS now; GeoIP/ASN later).

  This worker is intentionally SRQL-driven:
  - it discovers candidate IPs via SRQL flow stats queries
  - it stores enrichment in cache tables keyed by IP with TTL
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.{IpRdnsCache, SRQLRunner}
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Ash.Query
  require Logger

  @default_scan_window "last_1h"
  @default_limit 200
  @default_rdns_ttl_seconds 86_400
  @default_rdns_timeout_ms 250
  @default_reschedule_seconds 300

  @doc """
  Schedules enrichment refresh if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      case check_existing_job() do
        true -> {:ok, :already_scheduled}
        false -> %{} |> new() |> ObanSupport.safe_insert()
      end
    else
      {:error, :oban_unavailable}
    end
  end

  defp check_existing_job do
    query =
      from(j in Oban.Job,
        where: j.worker == ^to_string(__MODULE__),
        where: j.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    Repo.exists?(query, prefix: ObanSupport.prefix())
  end

  @impl Oban.Worker
  def perform(_job) do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    scan_window = Keyword.get(config, :scan_window, @default_scan_window)
    limit = Keyword.get(config, :limit, @default_limit)
    rdns_ttl_seconds = Keyword.get(config, :rdns_ttl_seconds, @default_rdns_ttl_seconds)
    rdns_timeout_ms = Keyword.get(config, :rdns_timeout_ms, @default_rdns_timeout_ms)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, rdns_ttl_seconds, :second)

    actor = SystemActor.system(:ip_enrichment_refresh)

    ips = discover_candidate_ips(scan_window, limit)
    Enum.each(ips, &refresh_rdns(&1, actor, now, expires_at, rdns_timeout_ms))

    ObanSupport.safe_insert(new(%{}, schedule_in: max(reschedule_seconds, 30)))
    :ok
  end

  defp discover_candidate_ips(scan_window, limit) do
    base = "in:flows time:#{scan_window}"

    src_query =
      ~s|#{base} stats:"sum(bytes_total) as total_bytes by src_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    dst_query =
      ~s|#{base} stats:"sum(bytes_total) as total_bytes by dst_endpoint_ip" sort:total_bytes:desc limit:#{limit}|

    src_ips = extract_ips(SRQLRunner.query(src_query), "src_endpoint_ip")
    dst_ips = extract_ips(SRQLRunner.query(dst_query), "dst_endpoint_ip")

    (src_ips ++ dst_ips)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "—", "-", "Unknown"]))
    |> Enum.uniq()
  end

  defp extract_ips({:ok, rows}, key) when is_list(rows) and is_binary(key) do
    Enum.flat_map(rows, fn
      %{^key => ip} when is_binary(ip) -> [ip]
      %{"result" => %{} = payload} -> extract_ips({:ok, [payload]}, key)
      %{} -> []
      _ -> []
    end)
  end

  defp extract_ips(_other, _key), do: []

  defp refresh_rdns(ip, actor, now, expires_at, timeout_ms) when is_binary(ip) do
    {hostname, status, err} = rdns_lookup(ip, timeout_ms)

    existing_error_count =
      case Ash.read_one(IpRdnsCache |> Ash.Query.for_read(:by_ip, %{ip: ip}), actor: actor) do
        {:ok, %IpRdnsCache{error_count: n}} when is_integer(n) -> n
        _ -> 0
      end

    error_count =
      cond do
        is_nil(err) -> 0
        true -> existing_error_count + 1
      end

    attrs = %{
      ip: ip,
      hostname: hostname,
      status: status,
      looked_up_at: now,
      expires_at: expires_at,
      error: err,
      error_count: error_count
    }

    changeset =
      IpRdnsCache
      |> Ash.Changeset.for_create(:upsert, attrs)

    case Ash.create(changeset, actor: actor) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("IpEnrichmentRefreshWorker: failed to upsert rDNS cache",
          ip: ip,
          reason: inspect(reason)
        )

        :error
    end
  end

  defp rdns_lookup(ip, timeout_ms) when is_binary(ip) and is_integer(timeout_ms) do
    with {:ok, ip_tuple} <- parse_ip(ip) do
      task =
        Task.async(fn ->
          # Uses system resolver; wrapped in a strict timeout at the process level.
          case :inet.gethostbyaddr(ip_tuple) do
            {:ok, {:hostent, hostname, _aliases, _addrtype, _len, _addrs}} ->
              {:ok, hostname}

            {:error, reason} ->
              {:error, reason}
          end
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, hostname}} ->
          {to_string(hostname), "ok", nil}

        {:ok, {:error, reason}} ->
          {nil, "error", inspect(reason)}

        nil ->
          {nil, "timeout", "timeout"}
      end
    else
      {:error, reason} ->
        {nil, "error", reason}
    end
  end

  defp rdns_lookup(_ip, _timeout_ms), do: {nil, "error", "invalid_ip"}

  defp parse_ip(ip) when is_binary(ip) do
    ip = ip |> String.trim() |> String.split("/", parts: 2) |> List.first()

    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _} -> {:error, "invalid_ip"}
    end
  end
end
