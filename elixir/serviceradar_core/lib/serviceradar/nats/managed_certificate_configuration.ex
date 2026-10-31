defmodule ServiceRadar.NATS.ManagedCertificateConfiguration do
  @moduledoc """
  Explicit, deployment-owned bootstrap of the NATS certificate authorizer.

  The returned projection contains only public NKEYs. Operators install those
  in the broker configuration; signing seeds remain encrypted in CNPG. Creating
  the record does not claim the broker has applied it or enforcement is ready.
  """
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ManagedCertificateNatsConfig
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.NATS.CertificateAuthorizationToken

  @public_fields [:auth_mode, :account_name, :issuer_nkey, :auth_nkey, :system_nkey]

  def bootstrap(account_name, actor) do
    cond do
      not RBAC.has_permission?(actor, "settings.edge.manage") ->
        {:error, :forbidden}

      not is_binary(account_name) or not Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, account_name) ->
        {:error, :invalid_account_name}

      true ->
        with {:ok, config} <- read() do
          configure(config, account_name)
        end
    end
  end

  def read do
    Ash.read_one(ManagedCertificateNatsConfig, actor: system_actor())
  end

  def credentials do
    case read() do
      {:ok, %ManagedCertificateNatsConfig{} = config} ->
        Ash.load(config, [:issuer_seed, :auth_seed, :system_seed], actor: system_actor())

      {:ok, nil} ->
        {:error, :not_configured}

      error ->
        error
    end
  end

  def public_config(config), do: Map.take(config, @public_fields)

  defp configure(nil, account_name) do
    issuer = CertificateAuthorizationToken.new_key(:account)
    auth = CertificateAuthorizationToken.new_key(:user)
    system = CertificateAuthorizationToken.new_key(:user)

    attrs = %{
      auth_mode: "static_mtls",
      account_name: account_name,
      issuer_nkey: issuer.public_key,
      issuer_seed: issuer.seed,
      auth_nkey: auth.public_key,
      auth_seed: auth.seed,
      system_nkey: system.public_key,
      system_seed: system.seed
    }

    case ManagedCertificateNatsConfig
         |> Ash.Changeset.for_create(:configure, attrs, actor: system_actor())
         |> Ash.create() do
      {:ok, config} ->
        {:ok, public_config(config)}

      {:error, error} ->
        # A concurrent bootstrap may have won the singleton insert. Reuse only
        # that same mode/account; never replace existing signing material.
        case read() do
          {:ok, %ManagedCertificateNatsConfig{} = config} -> configure(config, account_name)
          _ -> {:error, error}
        end
    end
  end

  defp configure(%{auth_mode: "static_mtls", account_name: name} = config, name),
    do: {:ok, public_config(config)}

  defp configure(_, _), do: {:error, :existing_nats_authentication_mode_conflicts}

  defp system_actor, do: SystemActor.system(:managed_certificate_nats)
end
