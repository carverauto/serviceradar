defmodule ServiceRadar.AgentConfig.Compilers.MapperCompiler do
  @moduledoc """
  Compiler for mapper discovery configurations.

  Transforms mapper discovery jobs into the JSON schema expected by the mapper
  discovery engine.
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.Plugins.ValueUtils
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  require Ash.Query
  require Logger

  @proxmox_provider "proxmox"
  @proxmox_candidate_probe_option "proxmox_candidate_probe_enabled"
  @default_workers 20
  @default_timeout "30s"
  @default_retries 3
  @default_max_active_jobs 100
  @default_result_retention "24h"

  @impl true
  def config_type, do: :mapper

  @impl true
  def source_resources do
    [
      MapperJob,
      MapperSeed,
      MapperUnifiController,
      MapperMikrotikController,
      Device,
      SNMPProfile,
      NetworkCredentialRule,
      NetworkCredentialSecret
    ]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    actor = opts[:actor] || SystemActor.system(:mapper_compiler)
    device_uid = opts[:device_uid]

    jobs = load_jobs(partition, agent_id, actor)

    # A failed credential read fails the compile: falling back to the default
    # credential would deliver a config that differs from what the data says
    # (the mapper host may have its own scoped credential), and ConfigServer
    # would cache it.
    with {:ok, base_credentials} <-
           resolve_credentials(device_uid, actor, agent_id: agent_id, partition: partition),
         {:ok, target_specific} <-
           target_specific_credentials(jobs, partition, agent_id, actor),
         {:ok, mikrotik_controllers} <- load_mikrotik_controllers(jobs, actor),
         {:ok, unifi_controllers} <- load_unifi_controllers(jobs, actor),
         {:ok, proxmox_candidate_probe?} <-
           proxmox_candidate_probe_enabled?(partition, agent_id, actor) do
      credentials = Map.put(base_credentials, "target_specific", target_specific)

      config = %{
        "workers" => @default_workers,
        "timeout" => @default_timeout,
        "retries" => @default_retries,
        "max_active_jobs" => @default_max_active_jobs,
        "result_retention" => @default_result_retention,
        "scheduled_jobs" =>
          Enum.map(jobs, &compile_job(&1, credentials, proxmox_candidate_probe?)),
        "mikrotik_apis" => mikrotik_controllers,
        "unifi_apis" => unifi_controllers
      }

      {:ok, config}
    end
  rescue
    e ->
      Logger.error("MapperCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  defp load_jobs(partition, agent_id, actor) do
    MapperJob
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent_id, partition: partition},
      actor: actor
    )
    |> Ash.Query.load([:seeds, :unifi_controllers, :mikrotik_controllers])
    |> Ash.read!()
  end

  defp load_mikrotik_controllers(jobs, actor) do
    jobs
    |> Enum.flat_map(fn job ->
      job.mikrotik_controllers || []
    end)
    |> reduce_compiled(&compile_mikrotik_controller(&1, actor))
  end

  defp compile_mikrotik_controller(controller, actor) do
    with {:ok, password} <-
           mapper_controller_secret(controller, :password, actor, ["password", "value", "secret"]) do
      {:ok,
       %{
         "base_url" => controller.base_url,
         "username" => controller.username,
         "password" => password,
         "name" => controller.name,
         "insecure_skip_verify" => controller.insecure_skip_verify
       }}
    end
  end

  defp load_unifi_controllers(jobs, actor) do
    jobs
    |> Enum.flat_map(fn job ->
      job.unifi_controllers || []
    end)
    |> reduce_compiled(&compile_unifi_controller(&1, actor))
  end

  defp compile_unifi_controller(controller, actor) do
    with {:ok, api_key} <-
           mapper_controller_secret(controller, :api_key, actor, [
             "api_key",
             "token",
             "value",
             "secret"
           ]) do
      {:ok,
       %{
         "base_url" => controller.base_url,
         "api_key" => api_key,
         "name" => controller.name,
         "insecure_skip_verify" => controller.insecure_skip_verify
       }}
    end
  end

  defp reduce_compiled(records, fun) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case fun.(record) do
        {:ok, compiled} -> {:cont, {:ok, [compiled | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      error -> error
    end
  end

  defp mapper_controller_secret(controller, legacy_field, actor, payload_keys) do
    case Map.get(controller, :credential_secret_id) do
      secret_id when is_binary(secret_id) and secret_id != "" ->
        resolve_mapper_controller_secret(controller, secret_id, actor, payload_keys)

      _ ->
        {:ok, string_or_empty(Map.get(controller, legacy_field))}
    end
  end

  defp resolve_mapper_controller_secret(controller, secret_id, actor, payload_keys) do
    broker_opts =
      [
        actor: actor,
        audit?: true,
        consumer_kind: :mapper,
        consumer_id: mapper_controller_consumer_id(controller),
        purpose: "mapper_discovery",
        target_kind: :mapper_controller,
        target_id: mapper_controller_consumer_id(controller),
        resolution_location: :control_plane
      ]

    case SecretBroker.resolve_network_credential_secret(secret_id, broker_opts) do
      {:ok, %{value: payload}} ->
        {:ok, payload_secret_value(payload, payload_keys)}

      {:error, reason} ->
        if CredentialResolver.credential_read_failure?(reason) do
          Logger.error(
            "MapperCompiler: mapper controller credential read failed for #{secret_id} - #{inspect(reason)}"
          )

          {:error, {:credential_resolution_failed, reason}}
        else
          Logger.warning(
            "MapperCompiler: failed to resolve mapper controller broker credential #{secret_id} - #{inspect(reason)}"
          )

          {:ok, ""}
        end
    end
  end

  defp mapper_controller_consumer_id(%MapperMikrotikController{id: id}),
    do: "mapper_mikrotik_controller:#{id}"

  defp mapper_controller_consumer_id(%MapperUnifiController{id: id}),
    do: "mapper_unifi_controller:#{id}"

  defp mapper_controller_consumer_id(%{id: id}), do: "mapper_controller:#{id}"

  defp payload_secret_value(payload, payload_keys) when is_binary(payload) do
    trimmed = String.trim(payload)

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) ->
        decoded
        |> first_payload_value(payload_keys)
        |> string_or_empty()

      _ ->
        trimmed
    end
  end

  defp payload_secret_value(_payload, _payload_keys), do: ""

  defp first_payload_value(payload, payload_keys) do
    Enum.find_value(payload_keys, fn key ->
      Map.get(payload, key) || Map.get(payload, known_payload_atom_key(key))
    end)
  end

  defp known_payload_atom_key("api_key"), do: :api_key
  defp known_payload_atom_key("password"), do: :password
  defp known_payload_atom_key("token"), do: :token
  defp known_payload_atom_key("value"), do: :value
  defp known_payload_atom_key("secret"), do: :secret
  defp known_payload_atom_key(_key), do: nil

  defp compile_job(job, credentials, proxmox_candidate_probe?) do
    mikrotik_controllers = job.mikrotik_controllers || []
    seeds = job.seeds || []
    unifi_controllers = job.unifi_controllers || []

    mikrotik_api_names =
      mikrotik_controllers |> Enum.map(& &1.name) |> Enum.reject(&nil_or_blank?/1)

    mikrotik_api_urls =
      mikrotik_controllers |> Enum.map(& &1.base_url) |> Enum.reject(&nil_or_blank?/1)

    unifi_api_names = unifi_controllers |> Enum.map(& &1.name) |> Enum.reject(&nil_or_blank?/1)
    unifi_api_urls = unifi_controllers |> Enum.map(& &1.base_url) |> Enum.reject(&nil_or_blank?/1)

    options = job.options || %{}

    options =
      options
      |> Map.put_new("mapper_job_id", to_string(job.id))
      |> Map.put_new("mapper_job_name", job.name)
      |> maybe_put_csv_option("mikrotik_api_names", mikrotik_api_names)
      |> maybe_put_csv_option("mikrotik_api_urls", mikrotik_api_urls)
      |> maybe_put_csv_option("unifi_api_names", unifi_api_names)
      |> maybe_put_csv_option("unifi_api_urls", unifi_api_urls)
      |> maybe_enable_proxmox_candidate_probe(job, proxmox_candidate_probe?)

    %{
      "name" => job.name,
      "interval" => job.interval,
      "enabled" => job.enabled,
      "seeds" => Enum.map(seeds, & &1.seed),
      "type" => Atom.to_string(job.discovery_type),
      "discovery_mode" => Atom.to_string(job.discovery_mode),
      "credentials" => credentials,
      "concurrency" => job.concurrency,
      "timeout" => job.timeout,
      "retries" => job.retries,
      "options" => options
    }
  end

  defp maybe_put_csv_option(options, _key, []), do: options

  defp maybe_put_csv_option(options, key, values) when is_list(values) do
    csv = values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(",")

    if csv == "" do
      options
    else
      Map.put_new(options, key, csv)
    end
  end

  defp maybe_enable_proxmox_candidate_probe(options, _job, false), do: options

  defp maybe_enable_proxmox_candidate_probe(options, %{discovery_mode: :snmp}, true), do: options

  defp maybe_enable_proxmox_candidate_probe(options, _job, true) do
    Map.put(options, @proxmox_candidate_probe_option, "true")
  end

  defp nil_or_blank?(nil), do: true
  defp nil_or_blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp nil_or_blank?(_), do: false

  defp string_or_empty(nil), do: ""
  defp string_or_empty(value) when is_binary(value), do: value
  defp string_or_empty(value), do: to_string(value)

  # A failed credential read fails the compile: falling back to the default
  # credential would deliver a config that differs from what the data says
  # (the mapper host may have its own scoped credential), and ConfigServer
  # would cache it. A deterministic SecretBroker refusal keeps the documented
  # default-credential fallback so a misconfigured credential cannot freeze
  # the mapper config.
  defp resolve_credentials(device_uid, actor, opts) do
    case CredentialResolver.resolve_for_device(device_uid, actor, opts) do
      {:ok, %{credential: nil}} ->
        resolve_default_credentials(actor, opts)

      {:ok, %{credential: credential}} ->
        {:ok, CredentialResolver.to_mapper_credentials(credential)}

      {:error, reason} ->
        if CredentialResolver.credential_read_failure?(reason) do
          Logger.error(
            "MapperCompiler: SNMP credential read failed for discovery jobs - #{inspect(reason)}"
          )

          {:error, {:credential_resolution_failed, reason}}
        else
          Logger.warning(
            "MapperCompiler: SNMP credential resolution refused for discovery jobs - #{inspect(reason)}; using default credentials"
          )

          resolve_default_credentials(actor, opts)
        end
    end
  end

  defp resolve_default_credentials(actor, opts) do
    case CredentialResolver.resolve_default(actor, opts) do
      {:ok, %{credential: nil}} ->
        Logger.warning("MapperCompiler: no default SNMP credentials resolved for discovery jobs")
        {:ok, %{"version" => "v2c"}}

      {:ok, %{credential: credential}} ->
        {:ok, CredentialResolver.to_mapper_credentials(credential)}

      {:error, reason} ->
        if CredentialResolver.credential_read_failure?(reason) do
          Logger.error(
            "MapperCompiler: default SNMP credential read failed for discovery jobs - #{inspect(reason)}"
          )

          {:error, {:credential_resolution_failed, reason}}
        else
          Logger.warning(
            "MapperCompiler: default SNMP credential resolution refused for discovery jobs - #{inspect(reason)}"
          )

          {:ok, %{"version" => "v2c"}}
        end
    end
  end

  defp target_specific_credentials(jobs, partition, agent_id, actor) do
    if snmp_discovery_jobs?(jobs) do
      target_credentials(jobs, partition, agent_id, actor)
    else
      {:ok, %{}}
    end
  end

  # Rules describe monitored devices, not the device hosting the mapper. Include
  # known matching targets so API/LLDP-discovered neighbours get the same scoped
  # credentials as explicitly configured seeds, without changing the fallback.
  defp target_credentials(jobs, partition, agent_id, actor) do
    seeds = Enum.flat_map(jobs, fn job -> Enum.map(job.seeds || [], & &1.seed) end)

    seed_devices =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(ip in ^seeds or hostname in ^seeds or uid in ^seeds)
      |> Page.stream!()
      |> Enum.to_list()

    rule_devices =
      partition
      |> credential_rule_scopes(agent_id)
      |> Enum.flat_map(fn {type, value} ->
        NetworkCredentialRule.list_enabled_for_scope!("snmp", type, value, actor: actor)
      end)
      |> Enum.filter(&(&1.purpose in [nil, "", "snmp_monitoring"]))
      |> Enum.flat_map(&credential_rule_devices(&1, actor))

    (seed_devices ++ rule_devices)
    |> Enum.uniq_by(& &1.uid)
    |> Enum.reject(&(is_nil(&1.ip) or &1.ip == "" or not is_nil(&1.deleted_at)))
    |> Enum.reduce_while({:ok, %{}}, fn device, {:ok, targets} ->
      case CredentialResolver.resolve_for_device(device.uid, actor,
             agent_id: agent_id,
             partition: partition
           ) do
        {:ok, %{credential: nil}} ->
          {:cont, {:ok, targets}}

        {:ok, %{credential: credential}} ->
          encoded = CredentialResolver.to_mapper_credentials(credential)
          {:cont, {:ok, put_target_credential(targets, device.ip, {:ok, encoded})}}

        {:error, reason} ->
          if CredentialResolver.credential_read_failure?(reason) do
            Logger.error(
              "MapperCompiler: SNMP credential read failed for mapper target #{device.ip} - #{inspect(reason)}"
            )

            {:halt, {:error, {:credential_resolution_failed, reason}}}
          else
            Logger.warning(
              "MapperCompiler: failed to resolve SNMP credentials for mapper target #{device.ip} - #{inspect(reason)}; suppressing SNMP for this address"
            )

            {:cont, {:ok, put_target_credential(targets, device.ip, :suppressed)}}
          end
      end
    end)
    |> case do
      {:ok, targets} ->
        {:ok,
         Map.new(targets, fn
           {ip, :suppressed} -> {ip, %{}}
           {ip, {:ok, encoded}} -> {ip, encoded}
         end)}

      error ->
        error
    end
  end

  # A rule whose target query cannot be read contributes no target credentials,
  # but the failure is logged so a credential DB outage is visible instead of
  # silently narrowing discovery. This is a deliberate degrade: the SNMP compiler
  # fails closed on the same read, but mapper discovery still has the seed
  # devices and the default credential fallback to work with.
  defp credential_rule_devices(rule, actor) do
    case SNMPCompiler.execute_target_query(rule.target_query, actor) do
      {:ok, devices} ->
        devices

      {:error, reason} ->
        Logger.warning(
          "MapperCompiler: failed to resolve SNMP credential rule targets for #{inspect(rule.target_query)} - #{inspect(reason)}; contributing no target credentials"
        )

        []
    end
  end

  defp put_target_credential(targets, ip, :suppressed), do: Map.put(targets, ip, :suppressed)

  defp put_target_credential(targets, ip, {:ok, encoded} = value) do
    case Map.get(targets, ip) do
      nil ->
        Map.put(targets, ip, value)

      :suppressed ->
        targets

      {:ok, ^encoded} ->
        targets

      {:ok, _different} ->
        Logger.warning(
          "MapperCompiler: conflicting SNMP credentials for shared mapper target #{ip}; suppressing SNMP for this address"
        )

        Map.put(targets, ip, :suppressed)
    end
  end

  defp snmp_discovery_jobs?(jobs), do: Enum.any?(jobs, &(&1.discovery_mode in [:snmp, :snmp_api]))

  defp proxmox_candidate_probe_enabled?(partition, agent_id, actor) do
    partition
    |> credential_rule_scopes(agent_id)
    |> Enum.reduce_while({:ok, false}, fn {scope_type, scope_value}, {:ok, enabled?} ->
      case NetworkCredentialRule.list_enabled_for_scope(
             @proxmox_provider,
             scope_type,
             scope_value,
             actor: actor
           ) do
        {:ok, rules} ->
          {:cont, {:ok, enabled? or Enum.any?(rules, &proxmox_auto_discovery_rule?/1)}}

        {:error, reason} ->
          if CredentialResolver.credential_read_failure?(reason) do
            Logger.error(
              "MapperCompiler: failed to read Proxmox auto-discovery credential rules for #{scope_type}:#{scope_value} - #{inspect(reason)}"
            )

            {:halt, {:error, reason}}
          else
            Logger.warning(
              "MapperCompiler: failed to check Proxmox auto-discovery credential rules for #{scope_type}:#{scope_value} - #{inspect(reason)}"
            )

            {:cont, {:ok, enabled?}}
          end
      end
    end)
  end

  defp credential_rule_scopes(partition, agent_id) do
    [
      {:agent, agent_id},
      {:partition, partition}
    ]
    |> Enum.reject(fn {_type, value} -> ValueUtils.blank_string?(value) end)
    |> Enum.uniq()
  end

  defp proxmox_auto_discovery_rule?(rule) do
    proxmox_inventory_rule?(rule) and metadata_bool(rule, "auto_discovery_enabled", false)
  end

  defp proxmox_inventory_rule?(rule) do
    case ValueUtils.string_value(rule, [:purpose, "purpose"]) do
      nil -> true
      "" -> true
      "inventory_enrichment" -> true
      _ -> false
    end
  end

  defp metadata_bool(rule, key, default) do
    metadata = ValueUtils.map_value(rule, [:metadata, "metadata"], stringify_keys: true) || %{}

    case ValueUtils.raw_value(metadata, [key]) do
      value when is_boolean(value) -> value
      value when is_binary(value) -> String.downcase(String.trim(value)) in ~w(true 1 yes on)
      _ -> default
    end
  end
end
