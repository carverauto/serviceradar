defmodule ServiceRadarWebNG.Edge.NatsDeploymentStatus do
  @moduledoc """
  Whether this dedicated deployment can issue collector NATS credentials.

  There is no per-account NATS provisioning job. The cluster URL is set at
  deploy time on `:serviceradar_web_ng` (`NATS_URL`). The Data Collectors page
  used to read `:serviceradar, :nats_url`, which web-ng never sets, so it sat
  on "Provisioning NATS Account" forever.
  """

  @type status :: :ready | :not_configured

  @type t :: %{
          status: status(),
          nats_url: String.t() | nil,
          account_public_key: String.t() | nil
        }

  @spec current() :: t()
  def current do
    url = nats_url()

    %{
      status: if(present?(url), do: :ready, else: :not_configured),
      nats_url: url,
      account_public_key: account_public_key()
    }
  end

  @spec nats_url() :: String.t() | nil
  def nats_url do
    first_present([
      Application.get_env(:serviceradar_web_ng, :nats_url),
      Application.get_env(:serviceradar, :nats_url)
    ])
  end

  @spec account_public_key() :: String.t() | nil
  def account_public_key do
    first_present([
      Application.get_env(:serviceradar_web_ng, :nats_account_public_key),
      Application.get_env(:serviceradar, :nats_account_public_key)
    ])
  end

  defp first_present(values), do: Enum.find_value(values, &normalize/1)

  defp normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""
end
