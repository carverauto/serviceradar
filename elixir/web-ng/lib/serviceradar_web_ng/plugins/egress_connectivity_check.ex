defmodule ServiceRadarWebNG.Plugins.EgressConnectivityCheck do
  @moduledoc """
  Probes the egress hosts first-party plugin sync depends on.

  First-party sync fails silently when the deployment's egress proxy ACL does
  not admit the GitHub or plugin registry hosts: the failure surfaces as a
  generic import rejection far from the cause. This check probes every
  required host through `ServiceRadar.HTTP.EgressClient` -- the same client,
  proxy, and error vocabulary the import uses -- and reports per-host reach
  plus a mapped reason for the blocked ones.
  """

  alias ServiceRadar.HTTP.EgressClient
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient
  alias ServiceRadarWebNG.Plugins.ImportFailureMessages

  @probe_connect_timeout 4_000

  @doc """
  The hosts a first-party sync must be able to reach, with why each is needed.
  """
  @spec required_hosts() :: [%{host: String.t(), purpose: String.t()}]
  def required_hosts do
    [
      %{host: "github.com", purpose: "repository browsing"},
      %{host: "api.github.com", purpose: "release index"},
      %{host: "release-assets.githubusercontent.com", purpose: "release assets"},
      %{host: "objects.githubusercontent.com", purpose: "release assets"},
      %{host: "github-releases.githubusercontent.com", purpose: "release assets"},
      %{host: FirstPartyReleaseClient.oci_registry(), purpose: "plugin OCI artifacts"}
    ]
  end

  @doc """
  Probes every required host through the egress client.

  Returns `%{results: [%{host, purpose, reachable, detail}], blocked: n}`.
  `reachable` means the connection traversed the egress path and got an HTTP
  response -- any status, including 404/401, proves the host is admitted by
  the proxy; a transport error is the blocked/unreachable signal.
  """
  @spec run(keyword()) :: %{results: [map()], blocked: non_neg_integer()}
  def run(opts \\ []) do
    prober = Keyword.get(opts, :prober, &probe_host/1)

    results =
      Enum.map(required_hosts(), fn %{host: host, purpose: purpose} ->
        case prober.(host) do
          :ok ->
            %{host: host, purpose: purpose, reachable: true, detail: nil}

          {:error, reason} ->
            %{host: host, purpose: purpose, reachable: false, detail: ImportFailureMessages.reason_to_text(reason)}
        end
      end)

    %{results: results, blocked: Enum.count(results, &(!&1.reachable))}
  end

  # One HEAD per host: enough for the proxy to admit or reject the CONNECT,
  # without transferring a body. An HTTP status of any value counts as
  # reachable; only a transport failure is a connectivity problem.
  defp probe_host(host) do
    case EgressClient.head("https://#{host}/", connect_timeout: @probe_connect_timeout) do
      {:ok, %Req.Response{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
