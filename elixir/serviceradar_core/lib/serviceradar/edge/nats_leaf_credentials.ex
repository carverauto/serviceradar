defmodule ServiceRadar.Edge.NatsLeafCredentials do
  @moduledoc """
  Mints NATS user credentials for an edge-site leaf server.

  The hub authenticates leaf servers by mTLS (see
  `ServiceRadar.Edge.NatsLeafCertificateIssuer`), so credentials are optional.
  When this deployment has a NATS account configured (`:nats_account_name` and
  `:nats_account_seed`, the same settings `ProvisionCollectorWorker` uses), a
  leaf-scoped user is minted through `ServiceRadar.NATS.AccountClient` and
  recorded as a `NatsCredential`. Without that configuration this returns
  `{:ok, nil}` and the bundle ships without a creds file. Placeholder
  credentials are never produced.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.NatsCredential

  @leaf_permissions %{
    publish_allow: [
      "logs.>",
      "otel.>",
      "events.>",
      "netflow.>",
      "flows.raw.>",
      "falco.>",
      "$JS.API.>",
      "$JS.ACK.>",
      "_INBOX.>"
    ],
    subscribe_allow: ["$JS.API.>", "$JS.ACK.>", "_INBOX.>"]
  }

  @doc """
  Returns `{:ok, creds_file_content}`, `{:ok, nil}` when no NATS account is
  configured, or `{:error, reason}` when minting fails.
  """
  @spec mint(map(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def mint(edge_site, opts \\ []) do
    account_client = Keyword.get(opts, :account_client, ServiceRadar.NATS.AccountClient)

    case account_config() do
      nil ->
        {:ok, nil}

      %{account_name: account_name, account_seed: account_seed} ->
        user_name = "leaf-#{edge_site.slug}"

        with {:ok, creds} <-
               account_client.generate_user_credentials(
                 account_name,
                 account_seed,
                 user_name,
                 :service,
                 permissions: @leaf_permissions
               ),
             {:ok, _credential} <- record_credential(edge_site, user_name, creds) do
          {:ok, creds.creds_file_content}
        end
    end
  end

  @doc false
  def leaf_permissions, do: @leaf_permissions

  defp account_config do
    name = Application.get_env(:serviceradar, :nats_account_name)
    seed = Application.get_env(:serviceradar, :nats_account_seed)

    if is_binary(name) and name != "" and is_binary(seed) and seed != "" do
      %{account_name: name, account_seed: seed}
    end
  end

  defp record_credential(edge_site, user_name, creds) do
    NatsCredential
    |> Ash.Changeset.for_create(
      :create,
      %{
        user_name: user_name,
        credential_type: :service,
        expires_at: creds.expires_at,
        metadata: %{
          purpose: "nats-leaf",
          edge_site_id: edge_site.id,
          edge_site_slug: edge_site.slug
        },
        user_public_key: creds.user_public_key,
        onboarding_package_id: nil
      },
      actor: SystemActor.system(:nats_leaf_credentials)
    )
    |> Ash.create()
  end
end
