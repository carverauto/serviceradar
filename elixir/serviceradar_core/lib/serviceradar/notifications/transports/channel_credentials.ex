defmodule ServiceRadar.Notifications.Transports.ChannelCredentials do
  @moduledoc """
  Resolves a notification channel's stored credential for control-plane delivery.

  An internally encrypted secret resolves directly. A secret held by an external
  provider resolves only through a broker grant, so for those the transport
  issues one bound to this channel, the delivery purpose and the control plane,
  with a short TTL, and resolves through it. The grant lifecycle and the
  resolution are both audited; the plaintext never leaves the call.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.SecretBroker

  @purpose "notification_delivery"
  @grant_ttl_seconds 60

  @doc "Broker scope for resolving a channel's credential on the control plane."
  @spec broker_opts(String.t()) :: keyword()
  def broker_opts(channel_id) do
    [
      resolution_location: :control_plane,
      consumer_kind: :northbound_action,
      consumer_id: channel_id,
      purpose: @purpose
    ]
  end

  @spec resolve(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve(secret_id, channel_id, transport, opts) do
    broker = Keyword.get(opts, :secret_broker, SecretBroker)
    broker_opts = Keyword.merge(broker_opts(channel_id), Keyword.get(opts, :broker_opts, []))

    case broker.resolve_network_credential_secret(secret_id, broker_opts) do
      {:error, :external_secret_requires_broker_grant} ->
        with {:ok, grant} <- issue_grant(secret_id, channel_id, transport) do
          broker.resolve_with_grant(grant, Keyword.put(broker_opts, :audit?, true))
        end

      result ->
        result
    end
  end

  @doc "Issues a short-lived grant binding `secret_id` to this channel on the control plane."
  @spec issue_grant(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def issue_grant(secret_id, channel_id, transport) do
    %{
      secret_id: secret_id,
      grant_type: "notification_delivery",
      consumer_kind: :northbound_action,
      consumer_id: channel_id,
      purpose: @purpose,
      target_kind: "notification_channel",
      target_id: channel_id,
      resolution_location: :control_plane,
      metadata: %{"transport" => transport},
      ttl_seconds: @grant_ttl_seconds
    }
    |> CredentialBrokerGrant.issue_attrs()
    |> CredentialBrokerGrant.issue_grant(actor: SystemActor.system(:notification_delivery))
  end
end
