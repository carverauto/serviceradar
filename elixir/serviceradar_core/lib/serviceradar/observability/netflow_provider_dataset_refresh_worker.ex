defmodule ServiceRadar.Observability.NetflowProviderDatasetRefreshWorker do
  @moduledoc """
  Refreshes the cloud-provider CIDR dataset used for ingestion-time flow enrichment.

  Source dataset:
  - https://raw.githubusercontent.com/rezmoss/cloud-provider-ip-addresses/main/all_providers/all_providers.json
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query, only: [from: 2]

  alias ServiceRadar.Observability.OutboundFeedPolicy
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport
  alias ServiceRadar.Types.Cidr

  require Logger

  @default_source_url "https://raw.githubusercontent.com/rezmoss/cloud-provider-ip-addresses/main/all_providers/all_providers.json"
  @default_timeout_ms 30_000
  @default_reschedule_seconds 24 * 3600
  @default_failure_reschedule_seconds 12 * 3600
  @insert_chunk_size 250
  @db_timeout_ms 120_000

  @doc """
  Schedules the refresh job if not already scheduled.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled do
    if ObanSupport.available?() do
      if check_existing_job() do
        {:ok, :already_scheduled}
      else
        %{} |> new() |> ObanSupport.safe_insert()
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
    if scheduler_node?() do
      do_perform()
    else
      Logger.debug("Skipping cloud-provider CIDR refresh on non-scheduler node",
        node: Node.self()
      )

      :ok
    end
  end

  defp do_perform do
    config = Application.get_env(:serviceradar_core, __MODULE__, [])
    source_url = Keyword.get(config, :source_url, @default_source_url)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    validate_url = Keyword.get(config, :validate_url, &OutboundFeedPolicy.validate/1)
    http_get = Keyword.get(config, :http_get, &default_http_get/2)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    failure_reschedule_seconds =
      Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)

    case fetch_provider_rows(source_url, timeout_ms,
           validate_url: validate_url,
           http_get: http_get
         ) do
      {:ok, payload, rows, etag} when rows != [] ->
        case promote_snapshot(source_url, payload, rows, etag) do
          :ok ->
            Logger.info("Cloud-provider CIDR dataset refreshed", rows: length(rows))
            schedule_next(reschedule_seconds)

          :unchanged ->
            Logger.info("Cloud-provider CIDR dataset unchanged", rows: length(rows))
            schedule_next(reschedule_seconds)

          {:error, reason} ->
            Logger.warning("Cloud-provider CIDR dataset promotion failed",
              reason: inspect(reason)
            )

            schedule_next(failure_reschedule_seconds)
        end

      {:ok, _payload, [], _etag} ->
        Logger.warning(
          "Cloud-provider CIDR dataset parsed empty; keeping last-known-good snapshot"
        )

        schedule_next(failure_reschedule_seconds)

      {:error, reason} ->
        Logger.warning("Cloud-provider CIDR dataset fetch failed",
          reason: OutboundFeedPolicy.format_reason(reason)
        )

        schedule_next(failure_reschedule_seconds)
    end
  end

  defp scheduler_node? do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

    cluster_coordinator =
      Application.get_env(:serviceradar_core, :cluster_coordinator, cluster_enabled)

    if cluster_enabled, do: cluster_coordinator == true, else: true
  end

  defp fetch_provider_rows(source_url, timeout_ms, opts) do
    validate_url = Keyword.get(opts, :validate_url, &OutboundFeedPolicy.validate/1)
    http_get = Keyword.get(opts, :http_get, &default_http_get/2)

    with :ok <- validate_url.(source_url),
         {:ok, %Req.Response{status: 200, body: body, headers: headers}} <-
           http_get.(source_url, OutboundFeedPolicy.req_opts(timeout_ms)),
         {:ok, list} <- parse_provider_payload(body),
         rows when is_list(rows) <- normalize_provider_rows(list) do
      payload = if is_binary(body), do: body, else: Jason.encode!(body)
      {:ok, payload, rows, header(headers, "etag")}
    else
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        with {:ok, list} <- parse_provider_payload(body),
             rows when is_list(rows) <- normalize_provider_rows(list) do
          payload = if is_binary(body), do: body, else: Jason.encode!(body)
          {:ok, payload, rows, header(headers, "etag")}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  defp default_http_get(url, opts), do: Req.get(url, opts)

  defp parse_provider_payload(body) when is_binary(body), do: Jason.decode(body)
  defp parse_provider_payload(body) when is_list(body), do: {:ok, body}
  defp parse_provider_payload(_), do: {:error, :invalid_payload}

  defp normalize_provider_rows(rows) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows
    |> Enum.reduce(%{}, fn row, acc ->
      cidr = value(row, "cidr")
      provider = row |> value("provider") |> normalize_label()

      with true <- is_binary(cidr),
           true <- cidr != "",
           {:ok, normalized_cidr} <- Cidr.cast_input(cidr, []),
           {:ok, native_cidr} <- Cidr.dump_to_native(normalized_cidr, []),
           true <- is_binary(provider),
           true <- provider != "" do
        key = {normalized_cidr, provider}

        Map.put(acc, key, %{
          cidr: native_cidr,
          provider: provider,
          service: row |> value("service") |> blank_to_nil(),
          region: row |> value("region") |> blank_to_nil(),
          ip_version: row |> value("ip_version") |> blank_to_nil(),
          inserted_at: now
        })
      else
        _ -> acc
      end
    end)
    |> Map.values()
  end

  defp promote_snapshot(source_url, payload, rows, etag) do
    snapshot_id = Ecto.UUID.dump!(Ecto.UUID.generate())
    source_sha256 = sha256(payload)
    record_count = length(rows)
    now = DateTime.truncate(DateTime.utc_now(), :second)

    if active_snapshot_current?(source_sha256, record_count) do
      :unchanged
    else
      do_promote_snapshot(snapshot_id, source_url, source_sha256, payload, rows, etag, now)
    end
  end

  defp active_snapshot_current?(source_sha256, record_count) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)
        FROM platform.netflow_provider_dataset_snapshots
        WHERE is_active = TRUE
          AND source_sha256 = $1
          AND record_count = $2
        """,
        [source_sha256, record_count],
        timeout: @db_timeout_ms
      )

    count > 0
  end

  defp do_promote_snapshot(snapshot_id, source_url, source_sha256, _payload, rows, etag, now) do
    fn ->
      {1, _} =
        Repo.insert_all(
          "netflow_provider_dataset_snapshots",
          [
            %{
              id: snapshot_id,
              source_url: source_url,
              source_etag: etag,
              source_sha256: source_sha256,
              fetched_at: now,
              promoted_at: nil,
              is_active: false,
              record_count: length(rows),
              metadata: %{format: "all_providers.json"},
              inserted_at: now,
              updated_at: now
            }
          ],
          prefix: "platform",
          timeout: @db_timeout_ms
        )

      rows_to_insert = Enum.map(rows, &Map.put(&1, :snapshot_id, snapshot_id))
      count = insert_provider_rows(rows_to_insert)

      Repo.query!(
        "UPDATE platform.netflow_provider_dataset_snapshots SET is_active = FALSE, updated_at = now() WHERE id <> $1 AND is_active = TRUE",
        [snapshot_id],
        timeout: @db_timeout_ms
      )

      Repo.query!(
        "UPDATE platform.netflow_provider_dataset_snapshots SET is_active = TRUE, promoted_at = now(), updated_at = now() WHERE id = $1",
        [snapshot_id],
        timeout: @db_timeout_ms
      )

      if count == 0 do
        Repo.rollback(:no_rows_inserted)
      else
        :ok
      end
    end
    |> Repo.transaction(timeout: @db_timeout_ms)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_next(seconds) when is_integer(seconds) do
    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 3_600)))
    :ok
  end

  defp header(headers, name) do
    headers
    |> List.wrap()
    |> Enum.find_value(fn
      {k, value} -> if String.downcase(k) == name, do: value
      _ -> nil
    end)
  end

  defp sha256(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp normalize_label(nil), do: nil

  defp normalize_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      v -> v
    end
  end

  defp normalize_label(_), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp blank_to_nil(value), do: to_string(value)

  defp insert_provider_rows(rows) when is_list(rows) do
    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} =
        Repo.insert_all("netflow_provider_cidrs", chunk,
          prefix: "platform",
          on_conflict: :nothing,
          timeout: @db_timeout_ms
        )

      acc + count
    end)
  end
end
