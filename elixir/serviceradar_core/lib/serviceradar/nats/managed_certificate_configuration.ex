defmodule ServiceRadar.NATS.ManagedCertificateConfiguration do
  @moduledoc """
  The signing keys of the NATS certificate authorizer.

  On a chart install with certificate authorization on, the three seeds are
  mounted from the issuer Secret (`:nats_callout_seeds_dir`), and the broker is
  configured with their public keys from the same provisioning. The mounted
  seeds are then the only keys the broker accepts, so they are used and a
  record stored here is ignored. A mount with a seed missing or unreadable is
  `{:error, :signing_keys_not_provisioned}`; it never falls back to a stored
  record, which the broker would not accept.

  Without a mount, the keys are the record `bootstrap/2` stores: an explicit,
  deployment-owned step for installs with no chart. The requested account must
  equal the deployment account, the returned projection contains only public
  NKEYs, and signing seeds remain encrypted in CNPG. Creating the record does
  not claim the broker has applied it or enforcement is ready.
  """
  alias NKEYS.Keypair
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Edge.ManagedCertificateNatsConfig
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.NATS.CertificateAuthorizationToken

  require Logger

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

  @seed_files [
    issuer: "nats-callout-issuer.seed",
    auth: "nats-callout-auth.seed",
    system: "nats-callout-system.seed"
  ]

  @doc "The directory the chart mounts the signing seeds in, or nil."
  def mounted_seeds_dir do
    case Application.get_env(:serviceradar, :nats_callout_seeds_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> nil
    end
  end

  def credentials do
    case mounted_seeds_dir() do
      nil -> stored_credentials()
      dir -> mounted_credentials(dir)
    end
  end

  defp mounted_credentials(dir) do
    with account when is_binary(account) <- deployment_account(),
         {:ok, issuer} <- mounted_key(dir, :issuer),
         {:ok, auth} <- mounted_key(dir, :auth),
         {:ok, system} <- mounted_key(dir, :system) do
      note_unused_stored_record()

      {:ok,
       %{
         auth_mode: "static_mtls",
         account_name: account,
         issuer_nkey: issuer.public_key,
         issuer_seed: issuer.seed,
         auth_nkey: auth.public_key,
         auth_seed: auth.seed,
         system_nkey: system.public_key,
         system_seed: system.seed
       }}
    else
      nil -> {:error, :nats_account_unconfigured}
      :error -> {:error, :signing_keys_not_provisioned}
    end
  end

  defp mounted_key(dir, name) do
    with {:ok, contents} <- File.read(Path.join(dir, Keyword.fetch!(@seed_files, name))),
         seed = String.trim(contents),
         {:ok, key} <- Keypair.from_seed(seed) do
      {:ok, %{seed: seed, public_key: Keypair.public_key(key)}}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # Said once per node: the record is harmless, and an operator who bootstrapped
  # through the API before the chart provisioned keys should know it is unused.
  defp note_unused_stored_record do
    if :persistent_term.get({__MODULE__, :stored_record_noted}, false) == false do
      :persistent_term.put({__MODULE__, :stored_record_noted}, true)

      case read() do
        {:ok, %ManagedCertificateNatsConfig{}} ->
          Logger.info(
            "The stored NATS certificate authorization signing record is unused: the mounted signing seeds are in effect"
          )

        _ ->
          :ok
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp stored_credentials do
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
