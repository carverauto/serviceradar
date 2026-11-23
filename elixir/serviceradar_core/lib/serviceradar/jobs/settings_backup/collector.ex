defmodule ServiceRadar.Jobs.SettingsBackup.Collector do
  @moduledoc """
  Collects declarative ServiceRadar settings and Terraform-compatible resource
  inventories into a deterministic, secret-free canonical JSON snapshot.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller, as: AnsibleController
  alias ServiceRadar.Automation.Ansible.PlaybookRepository, as: AnsibleRepository
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Edge.PipelineSetting
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Integrations.MapboxSettings
  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.Inventory.DeviceHostnameRdnsSettings
  alias ServiceRadar.Monitoring.PollingSchedule
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Observability.NetflowSettings
  alias ServiceRadar.Observability.WarehouseRetentionSetting
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  @schema_version 1

  @allowed_secret_ref_keys MapSet.new([
                             "access_token_present",
                             "api_key_present",
                             "api_key_secret_id",
                             "callback_credential_secret_id",
                             "credential_provider",
                             "credential_secret_id",
                             "credentials_configured",
                             "execution_credential_secret_id",
                             "external_secret_fields",
                             "external_secret_ref",
                             "external_secret_version",
                             "ipinfo_api_key_present",
                             "otx_api_key_present",
                             "otx_credential_secret_id",
                             "password_present",
                             "password_secret_id",
                             "public_fingerprint",
                             "secret_id",
                             "secret_provider_id",
                             "sync_credential_secret_id",
                             "values_version"
                           ])

  @sensitive_substrings [
    "secret",
    "token",
    "password",
    "private_key",
    "encrypted_",
    "values_wo",
    "access_key_id",
    "secret_access_key",
    "community"
  ]

  @type snapshot :: %{
          bundle: map(),
          json: binary(),
          sha256: String.t(),
          sha256_prefix: String.t(),
          exported_at: DateTime.t(),
          reason: String.t()
        }

  @spec collect(keyword()) :: {:ok, snapshot()}
  def collect(opts \\ []) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:settings_backup)
    exported_at = Keyword.get(opts, :exported_at) || DateTime.utc_now()
    reason = Keyword.get(opts, :reason) || "scheduled"
    readers = Keyword.get(opts, :readers, %{})

    bundle = %{
      "schema_version" => @schema_version,
      "exported_at" => DateTime.to_iso8601(exported_at),
      "reason" => to_string(reason),
      "terraform_resources" => %{
        "serviceradar_network_credential_secret" =>
          :network_credential_secrets
          |> collect_records(NetworkCredentialSecret, actor, readers)
          |> Enum.map(&serialize_credential_secret/1)
          |> sort_by_id(),
        "serviceradar_network_credential_rule" =>
          :network_credential_rules
          |> collect_records(NetworkCredentialRule, actor, readers)
          |> Enum.map(&serialize_credential_rule/1)
          |> sort_by_id(),
        "serviceradar_ansible_controller" =>
          :ansible_controllers
          |> collect_records(AnsibleController, actor, readers)
          |> Enum.map(&serialize_ansible_controller/1)
          |> sort_by_id(),
        "serviceradar_ansible_repository" =>
          :ansible_repositories
          |> collect_records(AnsibleRepository, actor, readers)
          |> Enum.map(&serialize_ansible_repository/1)
          |> sort_by_id()
      },
      "settings" => %{
        "snmp_profiles" =>
          :snmp_profiles
          |> collect_records(SNMPProfile, actor, readers)
          |> Enum.map(&serialize_snmp_profile/1)
          |> sort_by_id(),
        "sweep_profiles" =>
          :sweep_profiles
          |> collect_records(SweepProfile, actor, readers)
          |> Enum.map(&serialize_sweep_profile/1)
          |> sort_by_id(),
        "sweep_groups" =>
          :sweep_groups
          |> collect_records(SweepGroup, actor, readers)
          |> Enum.map(&serialize_sweep_group/1)
          |> sort_by_id(),
        "polling_schedules" =>
          :polling_schedules
          |> collect_records(PollingSchedule, actor, readers)
          |> Enum.map(&serialize_polling_schedule/1)
          |> sort_by_id(),
        "service_checks" =>
          :service_checks
          |> collect_records(ServiceCheck, actor, readers)
          |> Enum.map(&serialize_service_check/1)
          |> sort_by_id(),
        "sysmon_profiles" =>
          :sysmon_profiles
          |> collect_records(SysmonProfile, actor, readers)
          |> Enum.map(&serialize_sysmon_profile/1)
          |> sort_by_id(),
        "edge_pipeline_settings" =>
          :edge_pipeline_settings
          |> collect_records(PipelineSetting, actor, readers)
          |> Enum.map(&serialize_pipeline_setting/1)
          |> Enum.sort_by(&{&1["scope"], &1["scope_key"], &1["id"]}),
        "warehouse_retention_settings" =>
          :warehouse_retention_settings
          |> collect_records(WarehouseRetentionSetting, actor, readers)
          |> Enum.map(&serialize_warehouse_retention_setting/1)
          |> Enum.sort_by(&{&1["dataset"], &1["id"]}),
        "device_hostname_rdns_settings" =>
          :device_hostname_rdns_settings
          |> collect_records(DeviceHostnameRdnsSettings, actor, readers)
          |> Enum.map(&serialize_device_hostname_rdns_settings/1)
          |> Enum.sort_by(& &1["key"]),
        "role_profiles" =>
          :role_profiles
          |> collect_records(RoleProfile, actor, readers)
          |> Enum.map(&serialize_role_profile/1)
          |> sort_by_id(),
        "authorization_settings" =>
          :authorization_settings
          |> collect_records(AuthorizationSettings, actor, readers)
          |> Enum.map(&serialize_authorization_settings/1)
          |> Enum.sort_by(& &1["key"]),
        "outbound_mail_settings" =>
          :outbound_mail_settings
          |> collect_records(OutboundMailSettings, actor, readers)
          |> Enum.map(&serialize_outbound_mail_settings/1)
          |> sort_by_id(),
        "netflow_settings" =>
          :netflow_settings
          |> collect_records(NetflowSettings, actor, readers)
          |> Enum.map(&serialize_netflow_settings/1)
          |> sort_by_id(),
        "mapbox_settings" =>
          :mapbox_settings
          |> collect_records(MapboxSettings, actor, readers)
          |> Enum.map(&serialize_mapbox_settings/1)
          |> sort_by_id()
      }
    }

    canonical = canonicalize(bundle)
    json = Jason.encode!(canonical)
    sha256 = :sha256 |> :crypto.hash(json) |> Base.encode16(case: :lower)

    {:ok,
     %{
       bundle: bundle,
       json: json,
       sha256: sha256,
       sha256_prefix: binary_part(sha256, 0, 12),
       exported_at: exported_at,
       reason: to_string(reason)
     }}
  end

  defp collect_records(key, resource, actor, readers) do
    case Map.get(readers, key) do
      reader when is_function(reader, 1) ->
        actor |> reader.() |> List.wrap()

      reader when is_function(reader, 0) ->
        List.wrap(reader.())

      nil ->
        safe_ash_read(resource, actor)
    end
  end

  defp safe_ash_read(resource, actor) do
    case Ash.read(resource, actor: actor) do
      {:ok, %Ash.Page.Keyset{results: results}} -> results
      {:ok, %Ash.Page.Offset{results: results}} -> results
      {:ok, results} when is_list(results) -> results
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp serialize_credential_secret(record) do
    metadata = get_field(record, :metadata)

    auth_method =
      if is_map(metadata), do: Map.get(metadata, "auth_method") || Map.get(metadata, :auth_method)

    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "credential_provider" => get_field(record, :provider),
      "auth_method" => auth_method,
      "credential_kind" => atom_or_string(get_field(record, :credential_kind)),
      "username" => get_field(record, :username),
      "public_fingerprint" => get_field(record, :public_fingerprint),
      "managed_by" => atom_or_string(get_field(record, :managed_by)),
      "credential_generation" => get_field(record, :credential_generation),
      "source_type" => atom_or_string(get_field(record, :source_type)),
      "rotation_state" => atom_or_string(get_field(record, :rotation_state)),
      "last_rotated_at" => format_datetime(get_field(record, :last_rotated_at)),
      "values_version" => 1,
      "metadata" => sanitize_map(metadata)
    }
  end

  defp serialize_credential_rule(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "credential_provider" => get_field(record, :provider),
      "auth_method" => get_field(record, :auth_method),
      "purpose" => get_field(record, :purpose),
      "target_query" => get_field(record, :target_query),
      "scope_type" => atom_or_string(get_field(record, :scope_type)),
      "scope_value" => get_field(record, :scope_value),
      "secret_id" => get_field(record, :secret_id),
      "allowed_ports" => record |> get_field(:allowed_ports) |> List.wrap() |> Enum.sort(),
      "tls_policy" => atom_or_string(get_field(record, :tls_policy)),
      "ssh_host_key_policy" => atom_or_string(get_field(record, :ssh_host_key_policy)),
      "ca_bundle_pem" => get_field(record, :ca_bundle_pem),
      "server_cert_fingerprint" => get_field(record, :server_cert_fingerprint),
      "priority" => get_field(record, :priority),
      "enabled" => get_field(record, :enabled),
      "metadata" => sanitize_map(get_field(record, :metadata))
    }
  end

  defp serialize_ansible_controller(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "base_url" => get_field(record, :base_url),
      "agent_id" => get_field(record, :agent_id),
      "sync_credential_secret_id" =>
        get_field(record, :sync_credential_secret_id) || get_field(record, :credential_secret_id),
      "execution_credential_secret_id" => get_field(record, :execution_credential_secret_id),
      "callback_credential_secret_id" => get_field(record, :callback_credential_secret_id),
      "inventory_sync_interval_seconds" => get_field(record, :inventory_sync_interval_seconds),
      "catalog_sync_interval_seconds" => get_field(record, :catalog_sync_interval_seconds),
      "enabled" => get_field(record, :enabled),
      "status" => atom_or_string(get_field(record, :status)),
      "awx_version" => get_field(record, :awx_version),
      "metadata" => sanitize_map(get_field(record, :metadata))
    }
  end

  defp serialize_ansible_repository(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "git_url" => get_field(record, :git_url),
      "git_ref" => get_field(record, :git_ref),
      "sync_interval_seconds" => get_field(record, :sync_interval_seconds),
      "credential_secret_id" => get_field(record, :credential_secret_id),
      "last_sync_status" => atom_or_string(get_field(record, :last_sync_status)),
      "last_sync_at" => format_datetime(get_field(record, :last_sync_at)),
      "metadata" => sanitize_map(get_field(record, :metadata))
    }
  end

  defp serialize_snmp_profile(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "poll_interval" => get_field(record, :poll_interval),
      "timeout" => get_field(record, :timeout),
      "retries" => get_field(record, :retries),
      "is_default" => get_field(record, :is_default),
      "enabled" => get_field(record, :enabled),
      "target_query" => get_field(record, :target_query),
      "priority" => get_field(record, :priority),
      "version" => atom_or_string(get_field(record, :version)),
      "username" => get_field(record, :username),
      "security_level" => atom_or_string(get_field(record, :security_level)),
      "auth_protocol" => atom_or_string(get_field(record, :auth_protocol)),
      "priv_protocol" => atom_or_string(get_field(record, :priv_protocol)),
      "credential_secret_id" => get_field(record, :credential_secret_id),
      "oid_template_ids" => record |> get_field(:oid_template_ids) |> List.wrap() |> Enum.sort(),
      "agent_ids" => record |> get_field(:agent_ids) |> List.wrap() |> Enum.sort()
    }
  end

  defp serialize_sweep_profile(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "ports" => record |> get_field(:ports) |> List.wrap() |> Enum.sort(),
      "sweep_modes" => record |> get_field(:sweep_modes) |> List.wrap() |> Enum.sort(),
      "concurrency" => get_field(record, :concurrency),
      "timeout" => get_field(record, :timeout),
      "scan_timeout" => get_field(record, :scan_timeout),
      "icmp_settings" => sanitize_term(get_field(record, :icmp_settings)),
      "tcp_settings" => sanitize_term(get_field(record, :tcp_settings)),
      "banner_grab" => sanitize_term(get_field(record, :banner_grab)),
      "admin_only" => get_field(record, :admin_only),
      "enabled" => get_field(record, :enabled)
    }
  end

  defp serialize_sweep_group(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "partition" => get_field(record, :partition),
      "agent_id" => get_field(record, :agent_id),
      "agent_ids" => record |> get_field(:agent_ids) |> List.wrap() |> Enum.sort(),
      "enabled" => get_field(record, :enabled),
      "interval" => get_field(record, :interval),
      "schedule_type" => atom_or_string(get_field(record, :schedule_type)),
      "cron_expression" => get_field(record, :cron_expression),
      "target_query" => get_field(record, :target_query),
      "static_targets" => record |> get_field(:static_targets) |> List.wrap() |> Enum.sort(),
      "ports" => record |> get_field(:ports) |> List.wrap() |> Enum.sort(),
      "sweep_modes" => record |> get_field(:sweep_modes) |> List.wrap() |> Enum.sort(),
      "overrides" => sanitize_map(get_field(record, :overrides)),
      "profile_id" => get_field(record, :profile_id),
      "emit_availability_events" => get_field(record, :emit_availability_events),
      "discover_new_devices" => get_field(record, :discover_new_devices)
    }
  end

  defp serialize_polling_schedule(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "enabled" => get_field(record, :enabled),
      "schedule_type" => atom_or_string(get_field(record, :schedule_type)),
      "interval_seconds" => get_field(record, :interval_seconds),
      "cron_expression" => get_field(record, :cron_expression),
      "assignment_mode" => atom_or_string(get_field(record, :assignment_mode)),
      "assigned_gateway_id" => get_field(record, :assigned_gateway_id),
      "assigned_partition_id" => get_field(record, :assigned_partition_id),
      "assigned_domain" => get_field(record, :assigned_domain),
      "priority" => get_field(record, :priority),
      "max_concurrent" => get_field(record, :max_concurrent),
      "timeout_seconds" => get_field(record, :timeout_seconds),
      "metadata" => sanitize_map(get_field(record, :metadata))
    }
  end

  defp serialize_service_check(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "enabled" => get_field(record, :enabled),
      "check_type" => atom_or_string(get_field(record, :check_type)),
      "target" => get_field(record, :target),
      "port" => get_field(record, :port),
      "interval_seconds" => get_field(record, :interval_seconds),
      "timeout_seconds" => get_field(record, :timeout_seconds),
      "retries" => get_field(record, :retries),
      "config" => sanitize_map(get_field(record, :config)),
      "warning_threshold_ms" => get_field(record, :warning_threshold_ms),
      "critical_threshold_ms" => get_field(record, :critical_threshold_ms),
      "agent_uid" => get_field(record, :agent_uid),
      "device_uid" => get_field(record, :device_uid),
      "web_property_id" => get_field(record, :web_property_id),
      "metadata" => sanitize_map(get_field(record, :metadata))
    }
  end

  defp serialize_sysmon_profile(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "sample_interval" => get_field(record, :sample_interval),
      "collect_cpu" => get_field(record, :collect_cpu),
      "collect_memory" => get_field(record, :collect_memory),
      "collect_disk" => get_field(record, :collect_disk),
      "collect_network" => get_field(record, :collect_network),
      "collect_processes" => get_field(record, :collect_processes),
      "process_limit" => get_field(record, :process_limit),
      "disk_paths" => record |> get_field(:disk_paths) |> List.wrap() |> Enum.sort(),
      "disk_exclude_paths" =>
        record |> get_field(:disk_exclude_paths) |> List.wrap() |> Enum.sort(),
      "thresholds" => sanitize_map(get_field(record, :thresholds)),
      "enabled" => get_field(record, :enabled),
      "target_query" => get_field(record, :target_query),
      "priority" => get_field(record, :priority)
    }
  end

  defp serialize_pipeline_setting(record) do
    %{
      "id" => get_field(record, :id),
      "scope" => atom_or_string(get_field(record, :scope)),
      "scope_key" => get_field(record, :scope_key),
      "horizon_seconds" => get_field(record, :horizon_seconds),
      "max_horizon_seconds" => get_field(record, :max_horizon_seconds),
      "spool_max_bytes" => get_field(record, :spool_max_bytes),
      "snmp_max_targets" => get_field(record, :snmp_max_targets),
      "late_admission_max_age_seconds" => get_field(record, :late_admission_max_age_seconds)
    }
  end

  defp serialize_warehouse_retention_setting(record) do
    %{
      "id" => get_field(record, :id),
      "dataset" => atom_or_string(get_field(record, :dataset)),
      "days" => get_field(record, :days),
      "seed_days" => get_field(record, :seed_days)
    }
  end

  defp serialize_device_hostname_rdns_settings(record) do
    %{
      "key" => get_field(record, :key),
      "enabled" => get_field(record, :enabled),
      "cron" => get_field(record, :cron),
      "timezone" => get_field(record, :timezone),
      "srql_query" => get_field(record, :srql_query),
      "batch_size" => get_field(record, :batch_size),
      "timeout_ms" => get_field(record, :timeout_ms),
      "retry_after_minutes" => get_field(record, :retry_after_minutes),
      "overwrite_existing" => get_field(record, :overwrite_existing)
    }
  end

  defp serialize_role_profile(record) do
    %{
      "id" => get_field(record, :id),
      "name" => get_field(record, :name),
      "description" => get_field(record, :description),
      "system" => get_field(record, :system),
      "system_name" => get_field(record, :system_name),
      "permissions" => record |> get_field(:permissions) |> List.wrap() |> Enum.sort()
    }
  end

  defp serialize_authorization_settings(record) do
    %{
      "key" => get_field(record, :key),
      "default_role" => atom_or_string(get_field(record, :default_role)),
      "role_mappings" => sanitize_term(get_field(record, :role_mappings)),
      "default_homepage" => sanitize_term(get_field(record, :default_homepage)),
      "cli_auth_enabled" => get_field(record, :cli_auth_enabled),
      "cli_session_ttl_days" => get_field(record, :cli_session_ttl_days),
      "cli_allowed_scopes" =>
        record |> get_field(:cli_allowed_scopes) |> List.wrap() |> Enum.sort()
    }
  end

  defp serialize_outbound_mail_settings(record) do
    %{
      "id" => get_field(record, :id),
      "enabled" => get_field(record, :enabled),
      "adapter" => get_field(record, :adapter),
      "from_name" => get_field(record, :from_name),
      "from_email" => get_field(record, :from_email),
      "relay" => get_field(record, :relay),
      "port" => get_field(record, :port),
      "hostname" => get_field(record, :hostname),
      "username" => get_field(record, :username),
      "password_secret_id" => get_field(record, :password_secret_id),
      "api_key_secret_id" => get_field(record, :api_key_secret_id),
      "password_present" => ciphertext_present?(record, :encrypted_password, :password_present),
      "api_key_present" => ciphertext_present?(record, :encrypted_api_key, :api_key_present),
      "auth" => get_field(record, :auth),
      "tls" => get_field(record, :tls),
      "ssl" => get_field(record, :ssl),
      "retries" => get_field(record, :retries),
      "provider_options" => sanitize_map(get_field(record, :provider_options))
    }
  end

  defp serialize_netflow_settings(record) do
    %{
      "id" => get_field(record, :id),
      "geoip_enabled" => get_field(record, :geoip_enabled),
      "ipinfo_enabled" => get_field(record, :ipinfo_enabled),
      "ipinfo_base_url" => get_field(record, :ipinfo_base_url),
      "ipinfo_api_key_present" =>
        ciphertext_present?(record, :encrypted_ipinfo_api_key, :ipinfo_api_key_present),
      "threat_intel_enabled" => get_field(record, :threat_intel_enabled),
      "otx_enabled" => get_field(record, :otx_enabled),
      "otx_execution_mode" => get_field(record, :otx_execution_mode),
      "otx_credential_secret_id" => get_field(record, :otx_credential_secret_id),
      "otx_base_url" => get_field(record, :otx_base_url),
      "otx_sync_interval_seconds" => get_field(record, :otx_sync_interval_seconds),
      "otx_page_size" => get_field(record, :otx_page_size),
      "otx_timeout_ms" => get_field(record, :otx_timeout_ms)
    }
  end

  defp serialize_mapbox_settings(record) do
    %{
      "id" => get_field(record, :id),
      "enabled" => get_field(record, :enabled),
      "style_light" => get_field(record, :style_light),
      "style_dark" => get_field(record, :style_dark),
      "access_token_present" =>
        ciphertext_present?(record, :encrypted_access_token, :access_token_present)
    }
  end

  defp ciphertext_present?(record, encrypted_field, calc_field) do
    case get_field(record, calc_field) do
      val when is_boolean(val) ->
        val

      _ ->
        case get_field(record, encrypted_field) do
          bin when is_binary(bin) -> byte_size(bin) > 0
          _ -> false
        end
    end
  end

  defp sort_by_id(list), do: Enum.sort_by(list, &to_string(&1["id"] || ""))

  defp get_field(record, key) when is_map(record) do
    case Map.fetch(record, key) do
      {:ok, %Ash.NotLoaded{}} -> nil
      {:ok, %Ash.ForbiddenField{}} -> nil
      {:ok, value} -> value
      :error -> Map.get(record, Atom.to_string(key))
    end
  end

  defp atom_or_string(nil), do: nil
  defp atom_or_string(val) when is_atom(val), do: Atom.to_string(val)
  defp atom_or_string(val), do: val

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_datetime(val) when is_binary(val), do: val

  defp sanitize_map(nil), do: %{}

  defp sanitize_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> sensitive_key?(to_string(k)) end)
    |> Map.new(fn {k, v} -> {to_string(k), sanitize_term(v)} end)
  end

  defp sanitize_map(_), do: %{}

  defp sanitize_term(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp sanitize_term(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp sanitize_term(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> sanitize_map()
  end

  defp sanitize_term(map) when is_map(map), do: sanitize_map(map)
  defp sanitize_term(list) when is_list(list), do: Enum.map(list, &sanitize_term/1)

  defp sanitize_term(atom) when is_atom(atom) and not is_boolean(atom) and not is_nil(atom),
    do: Atom.to_string(atom)

  defp sanitize_term(other), do: other

  defp sensitive_key?(key) do
    down = String.downcase(key)

    if MapSet.member?(@allowed_secret_ref_keys, down) do
      false
    else
      Enum.any?(@sensitive_substrings, &String.contains?(down, &1))
    end
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other
end
