defmodule ServiceRadar.Security.PeerCertificatePolicySupervisor do
  @moduledoc "Supervises the replica-local policy and its independent HTTPS refresh path."
  use Supervisor

  alias ServiceRadar.Security.PeerCertificatePolicy
  alias ServiceRadar.Security.PeerCertificatePolicyRefresh
  alias ServiceRadar.Security.PeerCertificateTransportTasks

  def child do
    config =
      Application.get_env(:serviceradar_core, :peer_certificate_policy) || environment_config()

    if config, do: {__MODULE__, config}
  end

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {Task.Supervisor, name: PeerCertificateTransportTasks},
      {PeerCertificatePolicy, task_supervisor: PeerCertificateTransportTasks},
      {PeerCertificatePolicyRefresh, Keyword.put(opts, :name, PeerCertificatePolicyRefresh)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp environment_config do
    url = System.get_env("SERVICERADAR_CERT_POLICY_URL")
    key = System.get_env("SERVICERADAR_CERT_POLICY_KEY_FILE")

    if url || key do
      if !(is_binary(url) and url != "" and is_binary(key) and key != "") do
        raise "Managed peer policy requires SERVICERADAR_CERT_POLICY_URL and SERVICERADAR_CERT_POLICY_KEY_FILE"
      end

      http_options =
        case System.get_env("SERVICERADAR_CERT_POLICY_CA_FILE") do
          nil -> []
          path -> [cacertfile: path]
        end

      [url: url, public_key_file: key, http_options: http_options]
    end
  end
end
