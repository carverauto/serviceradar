defmodule Mix.Tasks.Serviceradar.WifiMap.Seed do
  @shortdoc "Ingest WiFi-map CSV seed files into the local ServiceRadar database"

  @moduledoc """
  Builds and optionally ingests a normalized WiFi-map batch from CSV seed files.

  This task is intended for local Docker Compose validation and customer plugin
  authoring checks. It uses the same `ServiceRadar.WifiMap.BatchIngestor`
  contract that plugin results use after they reach core-elx.

  Usage:

      mix serviceradar.wifi_map.seed --dir ../../tmp/wifi-map --dry-run
      mix serviceradar.wifi_map.seed --dir ../../tmp/wifi-map --partition local
      mix serviceradar.wifi_map.seed --dir ../../tmp/wifi-map --skip-device-sync
  """

  use Mix.Task

  alias ServiceRadar.WifiMap.BatchIngestor
  alias ServiceRadar.WifiMap.CSVSeedPayload

  @switches [
    collection_timestamp: :string,
    dir: :string,
    dry_run: :boolean,
    partition: :string,
    service_name: :string,
    skip_device_sync: :boolean,
    source_id: :string,
    source_name: :string
  ]

  @aliases [
    d: :dir
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    directory = Keyword.get(opts, :dir, "tmp/wifi-map")

    payload_opts =
      opts
      |> take_payload_opts()
      |> Keyword.put_new(:source_name, Keyword.get(opts, :source_name, "wifi-map-csv-seed"))

    case CSVSeedPayload.build(directory, payload_opts) do
      {:ok, payload, summary} ->
        if Keyword.get(opts, :dry_run, false) do
          print_summary("WiFi-map CSV seed dry run", summary)
        else
          Mix.Task.run("app.start")

          ingest_opts =
            if Keyword.get(opts, :skip_device_sync, false) do
              [device_sync: fn _updates, _context -> :ok end]
            else
              []
            end

          status = %{
            service_name: Keyword.get(opts, :service_name, "wifi-map-csv-seed"),
            partition: Keyword.get(opts, :partition, "local"),
            timestamp: payload["collection_timestamp"]
          }

          case BatchIngestor.ingest(payload, status, ingest_opts) do
            :ok ->
              print_summary("WiFi-map CSV seed ingested", summary)

            {:error, reason} ->
              Mix.raise("WiFi-map CSV seed ingest failed: #{inspect(reason)}")
          end
        end

      {:error, reason} ->
        Mix.raise("WiFi-map CSV seed build failed: #{inspect(reason)}")
    end
  end

  defp take_payload_opts(opts) do
    opts
    |> Keyword.take([:collection_timestamp, :source_id, :source_name])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp print_summary(title, summary) do
    Mix.shell().info(title)
    Mix.shell().info(Jason.encode!(summary, pretty: true))
  end
end
