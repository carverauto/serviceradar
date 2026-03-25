defmodule Mix.Tasks.Serviceradar.ExternalBoomboxWorker do
  @shortdoc "Starts the external Boombox-backed camera analysis worker"

  @moduledoc false
  use Mix.Task

  use Boundary,
    top_level?: true,
    check: [in: false, out: false]

  alias ServiceRadarCoreElx.CameraRelay.ExternalBoomboxAnalysisWorker

  def run(args) do
    {:ok, _started_apps} = Application.ensure_all_started(:serviceradar_core_elx)

    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [port: :integer, host: :string, worker_id: :string]
      )

    port = Keyword.get(opts, :port, 4101)
    ip = parse_host(Keyword.get(opts, :host, "127.0.0.1"))
    worker_id = Keyword.get(opts, :worker_id, "external-boombox-analysis-worker")

    {:ok, _pid} =
      Supervisor.start_link(
        [{ExternalBoomboxAnalysisWorker, port: port, ip: ip, worker_id: worker_id}],
        strategy: :one_for_one
      )

    IO.puts("external Boombox worker listening on http://#{format_ip(ip)}:#{port}")
    Process.sleep(:infinity)
  end

  defp parse_host(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _reason} -> raise ArgumentError, "invalid host: #{inspect(host)}"
    end
  end

  defp format_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp format_ip(other), do: to_string(:inet.ntoa(other))
end
