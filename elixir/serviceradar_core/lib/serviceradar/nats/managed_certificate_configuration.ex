defmodule ServiceRadar.NATS.ManagedCertificateConfiguration do
  @moduledoc """
  Explicit, deployment-owned bootstrap of the NATS certificate authorizer.

  The requested account must equal the deployment account. The returned
  projection contains only public NKEYs. Operators install those in the broker
  configuration; signing seeds remain encrypted in CNPG. Creating the record
  does not claim the broker has applied it or enforcement is ready.
  """
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ManagedCertificateNatsConfig
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.NATS.CertificateAuthorizationToken

  @public_fields [:auth_mode, :account_name, :issuer_nkey, :auth_nkey, :system_nkey]
  @account_name ~r/\A[A-Za-z0-9_-]+\z/

  @doc """
  The NATS account this deployment signs for.

  Returns nil when `:nats_account_name` is missing or not a legal account name.
  """
  def deployment_account do
    case Application.get_env(:serviceradar, :nats_account_name) do
      name when is_binary(name) -> if account_name?(name), do: name
      _ -> nil
    end
  end

  def bootstrap(account_name, actor) do
    configured = deployment_account()

    cond do
      not RBAC.has_permission?(actor, "settings.edge.manage") ->
        {:error, :forbidden}

      not account_name?(account_name) ->
        {:error, :invalid_account_name}

      configured == nil ->
        {:error, :nats_account_unconfigured}

      configured != account_name ->
        {:error, :nats_account_mismatch}

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

  defp account_name?(name) when is_binary(name), do: Regex.match?(@account_name, name)
  defp account_name?(_), do: false

  defp system_actor, do: SystemActor.system(:managed_certificate_nats)
end
