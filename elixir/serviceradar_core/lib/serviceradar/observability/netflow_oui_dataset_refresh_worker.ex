defmodule ServiceRadar.Observability.NetflowOuiDatasetRefreshWorker do
  @moduledoc """
  Refreshes IEEE OUI data used for MAC-vendor enrichment.

  Source dataset:
  - https://standards-oui.ieee.org/oui/oui.csv
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.ObanSupport

  import Ecto.Query, only: [from: 2]

  require Logger

  @default_source_url "https://standards-oui.ieee.org/oui/oui.csv"
  @default_timeout_ms 45_000
  @default_reschedule_seconds 7 * 86_400
  @default_failure_reschedule_seconds 12 * 3600
  @insert_chunk_size 250
  @db_timeout_ms 120_000

  @doc """
  Schedules the refresh job if not already scheduled.
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
    source_url = Keyword.get(config, :source_url, @default_source_url)
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)
    reschedule_seconds = Keyword.get(config, :reschedule_seconds, @default_reschedule_seconds)

    failure_reschedule_seconds =
      Keyword.get(config, :failure_reschedule_seconds, @default_failure_reschedule_seconds)

    case fetch_oui_rows(source_url, timeout_ms) do
      {:ok, payload, rows, etag} when rows != [] ->
        case promote_snapshot(source_url, payload, rows, etag) do
          :ok ->
            Logger.info("IEEE OUI dataset refreshed", rows: length(rows), source_url: source_url)
            schedule_next(reschedule_seconds)

          {:error, reason} ->
            Logger.warning("IEEE OUI dataset promotion failed", reason: inspect(reason))
            schedule_next(failure_reschedule_seconds)
        end

      {:ok, _payload, [], _etag} ->
        Logger.warning("IEEE OUI dataset parsed empty; keeping last-known-good snapshot")
        schedule_next(failure_reschedule_seconds)

      {:error, reason} ->
        Logger.warning("IEEE OUI dataset fetch failed", reason: inspect(reason))
        schedule_next(failure_reschedule_seconds)
    end
  end

  defp fetch_oui_rows(source_url, timeout_ms) do
    req_opts = [
      receive_timeout: timeout_ms,
      retry: false,
      finch: ServiceRadar.Finch
    ]

    case Req.get(source_url, req_opts) do
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} when is_binary(body) ->
        rows = parse_oui_csv_rows(body)
        {:ok, body, rows, header(headers, "etag")}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  defp parse_oui_csv_rows(body) when is_binary(body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    body
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.reduce(%{}, fn line, acc ->
      fields = split_csv_line(line)
      assignment = Enum.at(fields, 1)
      org = Enum.at(fields, 2)

      with true <- is_binary(assignment) and assignment != "",
           true <- is_binary(org) and String.trim(org) != "",
           hex <-
             assignment
             |> String.split("/", parts: 2)
             |> List.first()
             |> String.trim()
             |> String.upcase(),
           {prefix, ""} <- Integer.parse(hex, 16),
           true <- is_integer(prefix) and prefix >= 0 do
        Map.put(acc, prefix, %{
          oui_prefix_int: prefix,
          oui_prefix_hex: hex,
          organization: String.trim(org),
          inserted_at: now
        })
      else
        _ -> acc
      end
    end)
    |> Map.values()
  end

  defp promote_snapshot(source_url, payload, rows, etag) do
    snapshot_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      {1, _} =
        Repo.insert_all(
          "netflow_oui_dataset_snapshots",
          [
            %{
              id: snapshot_id,
              source_url: source_url,
              source_etag: etag,
              source_sha256: sha256(payload),
              fetched_at: now,
              promoted_at: nil,
              is_active: false,
              record_count: length(rows),
              metadata: %{format: "oui.csv"},
              inserted_at: now,
              updated_at: now
            }
          ],
          prefix: "platform",
          timeout: @db_timeout_ms
        )

      rows_to_insert = Enum.map(rows, &Map.put(&1, :snapshot_id, snapshot_id))
      count = insert_oui_rows(rows_to_insert)

      Repo.query!(
        "UPDATE platform.netflow_oui_dataset_snapshots SET is_active = FALSE, updated_at = now() WHERE id <> $1 AND is_active = TRUE",
        [snapshot_id],
        timeout: @db_timeout_ms
      )

      Repo.query!(
        "UPDATE platform.netflow_oui_dataset_snapshots SET is_active = TRUE, promoted_at = now(), updated_at = now() WHERE id = $1",
        [snapshot_id],
        timeout: @db_timeout_ms
      )

      if count == 0 do
        Repo.rollback(:no_rows_inserted)
      else
        :ok
      end
    end, timeout: @db_timeout_ms)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_next(seconds) when is_integer(seconds) do
    _ = ObanSupport.safe_insert(new(%{}, schedule_in: max(seconds, 3_600)))
    :ok
  end

  defp header(headers, name) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      {k, value} when is_binary(k) and is_binary(name) -> if String.downcase(k) == name, do: value
      _ -> nil
    end)
  end

  defp header(_, _), do: nil

  defp sha256(payload) when is_binary(payload) do
    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end

  defp split_csv_line(line) when is_binary(line) do
    chars = String.to_charlist(line)
    do_split_csv(chars, [], [], false)
  end

  defp do_split_csv([], field, acc, _in_quotes) do
    Enum.reverse([field_to_string(field) | acc])
  end

  defp do_split_csv([34, 34 | rest], field, acc, true),
    do: do_split_csv(rest, [34 | field], acc, true)

  defp do_split_csv([34 | rest], field, acc, in_quotes),
    do: do_split_csv(rest, field, acc, !in_quotes)

  defp do_split_csv([?, | rest], field, acc, false) do
    do_split_csv(rest, [], [field_to_string(field) | acc], false)
  end

  defp do_split_csv([ch | rest], field, acc, in_quotes),
    do: do_split_csv(rest, [ch | field], acc, in_quotes)

  defp field_to_string(chars) do
    chars
    |> Enum.reverse()
    |> to_string()
    |> String.trim()
    |> String.trim("\"")
  end

  defp insert_oui_rows(rows) when is_list(rows) do
    rows
    |> Enum.chunk_every(@insert_chunk_size)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} =
        Repo.insert_all("netflow_oui_prefixes", chunk,
          prefix: "platform",
          on_conflict: :nothing,
          timeout: @db_timeout_ms
        )

      acc + count
    end)
  end
end
