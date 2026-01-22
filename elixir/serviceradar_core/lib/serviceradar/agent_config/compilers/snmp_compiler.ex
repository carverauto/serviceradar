defmodule ServiceRadar.AgentConfig.Compilers.SNMPCompiler do
  @moduledoc """
  Compiler for SNMP configurations.

  Transforms SNMPProfile Ash resources into agent-consumable SNMP
  configuration format using SRQL-based targeting.

  ## Resolution Order

  When resolving which profile applies to a device:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile (fallback)

  Profiles use `target_query` (SRQL) to define which devices they apply to.
  Example: `target_query: "in:devices tags.role:network-monitor"` matches all
  devices with the tag `role=network-monitor`.

  ## Output Format

  The compiled config follows the proto SNMPConfig structure:

      %{
        "enabled" => true,
        "profile_id" => "uuid",
        "profile_name" => "Core Network Monitoring",
        "targets" => [
          %{
            "id" => "target-uuid",
            "name" => "Core Router 1",
            "host" => "192.168.1.1",
            "port" => 161,
            "version" => "v2c",
            "community" => "public",
            "poll_interval_seconds" => 60,
            "timeout_seconds" => 5,
            "retries" => 3,
            "oids" => [
              %{
                "oid" => ".1.3.6.1.2.1.2.2.1.10",
                "name" => "ifInOctets",
                "data_type" => "counter",
                "scale" => 1.0,
                "delta" => true
              }
            ]
          }
        ]
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SNMPProfiles.SNMPOIDConfig
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.Vault

  @impl true
  def config_type, do: :snmp

  @impl true
  def source_resources do
    [SNMPProfile, SNMPTarget, SNMPOIDConfig]
  end

  @impl true
  def compile(_partition, _agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:snmp_compiler)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device
    profile = resolve_profile(device_uid, actor)

    if profile && profile.enabled do
      config = compile_profile(profile, actor)
      {:ok, config}
    else
      # Return disabled config if no profile found or profile is disabled
      {:ok, disabled_config()}
    end
  rescue
    e ->
      Logger.error("SNMPCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "enabled") ->
        {:error, "Config missing 'enabled' key"}

      config["enabled"] and not Map.has_key?(config, "targets") ->
        {:error, "Config missing 'targets' key"}

      true ->
        :ok
    end
  end

  @doc """
  Resolves the SNMP profile for a device using SRQL targeting.

  Resolution order:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. Default profile

  Returns the matching SNMPProfile or nil if no profile matches.
  """
  @spec resolve_profile(String.t() | nil, map()) :: SNMPProfile.t() | nil
  def resolve_profile(device_uid, actor) do
    try_srql_targeting(device_uid, actor) ||
      get_default_profile(actor)
  end

  # Try to find a matching profile via SRQL targeting
  defp try_srql_targeting(nil, _actor), do: nil

  defp try_srql_targeting(device_uid, actor) do
    case SrqlTargetResolver.resolve_for_device(device_uid, actor) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        Logger.warning("SNMPCompiler: SRQL targeting failed - #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Compiles a profile to the agent config format with all targets and OIDs.
  """
  @spec compile_profile(SNMPProfile.t(), map()) :: map()
  def compile_profile(profile, actor) do
    # Load targets with their OID configs
    targets = load_profile_targets(profile.id, actor)

    compiled_targets =
      targets
      |> Enum.map(&compile_target(&1, actor))
      |> Enum.reject(&is_nil/1)

    %{
      "enabled" => profile.enabled and compiled_targets != [],
      "profile_id" => profile.id,
      "profile_name" => profile.name,
      "targets" => compiled_targets
    }
  end

  # Compile a single SNMP target with its OIDs
  defp compile_target(target, actor) do
    oids = load_target_oids(target.id, actor)

    compiled_oids =
      Enum.map(oids, fn oid ->
        %{
          "oid" => oid.oid,
          "name" => oid.name,
          "data_type" => Atom.to_string(oid.data_type),
          "scale" => oid.scale,
          "delta" => oid.delta
        }
      end)

    if compiled_oids == [] do
      Logger.debug(
        "SNMPCompiler: skipping target #{target.name} (no OIDs configured)"
      )

      nil
    else
      credential = resolve_target_credentials(target, actor)

      if valid_credentials?(credential) do
        version = Map.get(credential, :version, target.version)

        base_target = %{
          "id" => target.id,
          "name" => target.name,
          "host" => target.host,
          "port" => target.port,
          "version" => format_version(version),
          "poll_interval_seconds" => target.snmp_profile.poll_interval,
          "timeout_seconds" => target.snmp_profile.timeout,
          "retries" => target.snmp_profile.retries,
          "oids" => compiled_oids
        }

        # Add authentication based on version
        case version do
          :v1 ->
            Map.put(base_target, "community", Map.get(credential, :community))

          :v2c ->
            Map.put(base_target, "community", Map.get(credential, :community))

          :v3 ->
            Map.put(base_target, "v3_auth", compile_v3_auth(credential))
        end
      else
        Logger.warning(
          "SNMPCompiler: skipping target #{target.name} (missing credentials)"
        )

        nil
      end
    end
  end

  # Compile SNMPv3 authentication parameters
  defp compile_v3_auth(credential) do
    %{
      "username" => Map.get(credential, :username),
      "security_level" => format_security_level(Map.get(credential, :security_level)),
      "auth_protocol" => format_auth_protocol(Map.get(credential, :auth_protocol)),
      "auth_password" => Map.get(credential, :auth_password),
      "priv_protocol" => format_priv_protocol(Map.get(credential, :priv_protocol)),
      "priv_password" => Map.get(credential, :priv_password)
    }
  end

  # Decrypt an encrypted credential, returning nil if not set
  defp decrypt_credential(nil), do: nil

  defp decrypt_credential(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  defp resolve_target_credentials(target, actor) do
    case CredentialResolver.resolve_for_host(target.host, actor) do
      {:ok, %{credential: credential}} when is_map(credential) ->
        credential

      _ ->
        credential_from_target(target)
    end
  end

  defp credential_from_target(target) do
    %{
      version: target.version,
      community: decrypt_credential(target.community_encrypted),
      username: target.username,
      security_level: target.security_level,
      auth_protocol: target.auth_protocol,
      auth_password: decrypt_credential(target.auth_password_encrypted),
      priv_protocol: target.priv_protocol,
      priv_password: decrypt_credential(target.priv_password_encrypted)
    }
  end

  defp valid_credentials?(nil), do: false

  defp valid_credentials?(credential) when is_map(credential) do
    case Map.get(credential, :version, :v2c) do
      :v3 ->
        present?(Map.get(credential, :username)) or
          present?(Map.get(credential, :auth_password)) or
          present?(Map.get(credential, :priv_password))

      _ ->
        present?(Map.get(credential, :community))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  # Format version atom to string
  defp format_version(:v1), do: "v1"
  defp format_version(:v2c), do: "v2c"
  defp format_version(:v3), do: "v3"
  defp format_version(_), do: "v2c"

  # Format security level atom to string
  defp format_security_level(:no_auth_no_priv), do: "noAuthNoPriv"
  defp format_security_level(:auth_no_priv), do: "authNoPriv"
  defp format_security_level(:auth_priv), do: "authPriv"
  defp format_security_level(_), do: "noAuthNoPriv"

  # Format auth protocol atom to string
  defp format_auth_protocol(:md5), do: "MD5"
  defp format_auth_protocol(:sha), do: "SHA"
  defp format_auth_protocol(:sha224), do: "SHA-224"
  defp format_auth_protocol(:sha256), do: "SHA-256"
  defp format_auth_protocol(:sha384), do: "SHA-384"
  defp format_auth_protocol(:sha512), do: "SHA-512"
  defp format_auth_protocol(_), do: nil

  # Format priv protocol atom to string
  defp format_priv_protocol(:des), do: "DES"
  defp format_priv_protocol(:aes), do: "AES"
  defp format_priv_protocol(:aes192), do: "AES-192"
  defp format_priv_protocol(:aes256), do: "AES-256"
  defp format_priv_protocol(:aes192c), do: "AES-192-C"
  defp format_priv_protocol(:aes256c), do: "AES-256-C"
  defp format_priv_protocol(_), do: nil

  # Load all targets for a profile
  defp load_profile_targets(profile_id, actor) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile_id)
      |> Ash.Query.load(:snmp_profile)

    case Ash.read(query, actor: actor) do
      {:ok, targets} -> targets
      {:error, _} -> []
    end
  end

  # Load all OIDs for a target
  defp load_target_oids(target_id, actor) do
    query =
      SNMPOIDConfig
      |> Ash.Query.filter(snmp_target_id == ^target_id)

    case Ash.read(query, actor: actor) do
      {:ok, oids} -> oids
      {:error, _} -> []
    end
  end

  @doc """
  Returns disabled SNMP configuration when no profile is assigned.
  """
  @spec disabled_config() :: map()
  def disabled_config do
    %{
      "enabled" => false,
      "profile_id" => nil,
      "profile_name" => nil,
      "targets" => []
    }
  end

  # Get the default profile
  defp get_default_profile(actor) do
    query =
      SNMPProfile
      |> Ash.Query.for_read(:get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end
end
