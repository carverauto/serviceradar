defmodule ServiceRadar.Monitoring.CredentialPolicyCompiler do
  @moduledoc """
  Converts monitoring credential policy into broker-grant payloads.

  Monitoring bindings may reference unified network credential rules or explicit
  network credential secrets. This compiler keeps those references server-side
  and emits short-lived broker grants that agents can present back to the
  ServiceRadar agent-side broker for resolution.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Monitoring.MonitoredService
  alias ServiceRadar.Monitoring.MonitoringBinding
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.ValueUtils

  require Ash.Query

  @default_ttl_seconds 300

  @spec compile_for_service(
          MonitoringBinding.t(),
          MonitoredService.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def compile_for_service(
        %MonitoringBinding{} = binding,
        %MonitoredService{} = service,
        agent_uid,
        check_key,
        opts \\ []
      ) do
    actor = Keyword.get(opts, :actor, SystemActor.system(:monitoring_credential_policy))

    with {:ok, policy} <- effective_policy(binding.credential_policy, service, actor, opts) do
      case policy do
        policy when policy in [%{}, nil] ->
          {:ok, %{}}

        %{} = policy when is_map_key(policy, "mode") ->
          if grantless_policy?(policy) do
            {:ok, Map.drop(policy, ["secret_id", "secret_ref"])}
          else
            compile_policy(policy, binding, service, agent_uid, check_key, actor, opts)
          end

        %{} = policy ->
          compile_policy(policy, binding, service, agent_uid, check_key, actor, opts)
      end
    end
  end

  defp compile_policy(policy, binding, service, agent_uid, check_key, actor, opts) do
    with {:ok, expanded} <- expand_credential_rule(policy, actor, opts),
         {:ok, grant_attrs} <- grant_attrs(expanded, binding, service, agent_uid, check_key, opts),
         {:ok, grant} <- issue_grant(grant_attrs, actor, opts) do
      {:ok, snapshot_policy(expanded, grant)}
    end
  end

  defp effective_policy(policy, %MonitoredService{} = service, actor, opts) do
    policy = normalize_map(policy)
    service_override = service_credential_override(service)

    if map_size(service_override) > 0 do
      {:ok, Map.merge(policy, service_override)}
    else
      with {:ok, device_override} <- device_credential_override(service, actor, opts) do
        {:ok, Map.merge(policy, device_override)}
      end
    end
  end

  defp service_credential_override(%MonitoredService{metadata: metadata}) do
    metadata = normalize_map(metadata)

    metadata
    |> Map.get("credential_policy", Map.get(metadata, "credential_override", %{}))
    |> normalize_map()
  end

  defp device_credential_override(%MonitoredService{device_uid: device_uid}, actor, opts)
       when is_binary(device_uid) and device_uid != "" do
    case load_device(device_uid, actor, opts) do
      {:ok, %Device{metadata: metadata}} ->
        {:ok, metadata_credential_policy(metadata)}

      {:ok, %{metadata: metadata}} ->
        {:ok, metadata_credential_policy(metadata)}

      {:ok, nil} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp device_credential_override(_service, _actor, _opts), do: {:ok, %{}}

  defp load_device(device_uid, actor, opts) do
    case Keyword.get(opts, :device_loader) do
      nil -> Device.get_by_uid(device_uid, false, actor: actor)
      {module, function} -> apply(module, function, [device_uid, actor])
      fun when is_function(fun, 2) -> fun.(device_uid, actor)
      fun when is_function(fun, 1) -> fun.(device_uid)
    end
  end

  defp metadata_credential_policy(metadata) do
    metadata = normalize_map(metadata)

    metadata
    |> Map.get(
      "service_monitoring_credential_policy",
      Map.get(
        metadata,
        "credential_policy",
        Map.get(
          metadata,
          "credential_override",
          get_in(metadata, ["credentials", "monitoring_policy"])
        )
      )
    )
    |> normalize_map()
  end

  defp expand_credential_rule(policy, actor, opts) do
    case string_value(policy, "credential_rule_id") do
      nil ->
        {:ok, policy}

      credential_rule_id ->
        case credential_rule_by_id(credential_rule_id, actor, opts) do
          {:ok, %NetworkCredentialRule{} = rule} ->
            {:ok,
             policy
             |> Map.put_new("secret_id", rule.secret_id)
             |> Map.put_new("secret_ref", SecretRefs.network_credential_ref(rule.secret_id))
             |> Map.put_new("provider", rule.provider)
             |> Map.put_new("auth_method", Atom.to_string(rule.auth_method))
             |> Map.put_new("purpose", Atom.to_string(rule.purpose))
             |> Map.put_new("allowed_ports", rule.allowed_ports)
             |> Map.put_new("tls_policy", Atom.to_string(rule.tls_policy))
             |> Map.put_new("ssh_host_key_policy", Atom.to_string(rule.ssh_host_key_policy))}

          {:ok, nil} ->
            {:error, :credential_rule_not_found}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp credential_rule_by_id(credential_rule_id, actor, opts) do
    case Keyword.get(opts, :credential_rule_loader) do
      nil -> NetworkCredentialRule.get_by_id(credential_rule_id, actor: actor)
      {module, function} -> apply(module, function, [credential_rule_id, actor])
      fun when is_function(fun, 2) -> fun.(credential_rule_id, actor)
      fun when is_function(fun, 1) -> fun.(credential_rule_id)
    end
  end

  defp grant_attrs(policy, binding, service, agent_uid, check_key, opts) do
    secret_id = string_value(policy, "secret_id")
    secret_ref = string_value(policy, "secret_ref") || maybe_secret_ref(secret_id)

    if ValueUtils.blank_string?(secret_id) and ValueUtils.blank_string?(secret_ref) do
      {:error, :credential_policy_missing_secret}
    else
      descriptor = opts |> Keyword.get(:check_descriptor, %{}) |> normalize_map()

      with {:ok, allowlist} <- trusted_allowlist(policy, service, descriptor) do
        {:ok,
         %{
           secret_id: secret_id,
           secret_ref: secret_ref,
           credential_rule_id: string_value(policy, "credential_rule_id"),
           grant_type: grant_type(policy, binding, service, descriptor),
           consumer_kind: :service_monitoring,
           consumer_id: binding.id,
           purpose: credential_purpose(policy, descriptor),
           target_kind: "service",
           target_id: service.id,
           agent_id: agent_uid,
           resolution_location: resolution_location(policy),
           allowed_methods: allowlist.methods,
           allowed_paths: allowlist.paths,
           allowed_hosts: allowlist.hosts,
           allowed_ports: allowlist.ports,
           inject: inject_policy(policy, service, descriptor),
           metadata: %{
             "source" => "monitoring_binding",
             "monitoring_binding_id" => binding.id,
             "descriptor_id" => binding.descriptor_id,
             "descriptor_version" => binding.descriptor_version,
             "check_key" => check_key,
             "monitored_service_id" => service.id,
             "service_key" => service.service_key,
             "service_kind" => atom_to_string(service.service_kind),
             "protocol" => service.protocol
           },
           ttl_seconds: int_value(policy, "ttl_seconds", @default_ttl_seconds)
         }}
      end
    end
  end

  defp issue_grant(attrs, actor, opts) do
    issuer = Keyword.get(opts, :grant_issuer, default_grant_issuer(actor))

    case call_issuer(issuer, attrs, opts) do
      {:ok, %{} = grant} -> {:ok, CredentialBrokerGrant.to_payload(grant)}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_credential_grant_issuer_result, other}}
    end
  end

  defp default_grant_issuer(actor) do
    if SystemActor.system_actor?(actor) do
      fn attrs, _opts ->
        attrs
        |> CredentialBrokerGrant.issue_attrs()
        |> CredentialBrokerGrant.issue_grant(actor: actor)
      end
    else
      fn attrs, _opts ->
        {:ok, Map.put(CredentialBrokerGrant.issue_attrs(attrs), :id, test_grant_id())}
      end
    end
  end

  defp call_issuer({module, function}, attrs, opts), do: apply(module, function, [attrs, opts])
  defp call_issuer(fun, attrs, opts) when is_function(fun, 2), do: fun.(attrs, opts)
  defp call_issuer(fun, attrs, _opts) when is_function(fun, 1), do: fun.(attrs)

  defp snapshot_policy(policy, grant) do
    policy
    |> Map.drop(["secret_id", "secret_ref", "allowed_hosts", "hosts", "allowed_paths", "paths"])
    |> Map.put("credential_brokers", [grant])
    |> Map.put("credential_broker_grant_ids", grant_ids([grant]))
  end

  defp trusted_allowlist(policy, %MonitoredService{} = service, descriptor) do
    descriptor_allowlist = descriptor |> Map.get("allowlist_policy", %{}) |> normalize_map()
    hosts = trusted_hosts(service)
    paths = trusted_paths(service)
    ports = trusted_ports(service)

    with :ok <-
           requested_strings_match_target(
             policy["allowed_hosts"] || policy["hosts"],
             hosts,
             :allowed_hosts
           ),
         :ok <-
           requested_strings_match_target(
             descriptor_allowlist["allowed_hosts"] || descriptor_allowlist["hosts"],
             hosts,
             :allowed_hosts
           ),
         :ok <-
           requested_strings_match_target(
             policy["allowed_paths"] || policy["paths"],
             paths,
             :allowed_paths
           ),
         :ok <-
           requested_strings_match_target(
             descriptor_allowlist["allowed_paths"] || descriptor_allowlist["paths"],
             paths,
             :allowed_paths
           ),
         :ok <- requested_ports_match_target(policy["allowed_ports"] || policy["ports"], ports),
         :ok <-
           requested_ports_match_target(
             descriptor_allowlist["allowed_ports"] || descriptor_allowlist["ports"],
             ports
           ) do
      {:ok,
       %{
         hosts: hosts,
         paths: paths,
         ports: ports,
         methods:
           string_list(
             descriptor_allowlist["allowed_methods"] ||
               descriptor_allowlist["methods"] ||
               policy["allowed_methods"] ||
               policy["methods"]
           )
       }}
    end
  end

  defp requested_strings_match_target(nil, _trusted, _field), do: :ok

  defp requested_strings_match_target(requested, trusted, field) do
    requested = string_list(requested)
    trusted_set = MapSet.new(trusted)

    if Enum.all?(requested, &MapSet.member?(trusted_set, &1)) do
      :ok
    else
      {:error, {:credential_policy_allowlist_not_target_bound, field, requested}}
    end
  end

  defp requested_ports_match_target(nil, _trusted), do: :ok

  defp requested_ports_match_target(requested, trusted) do
    requested = integer_list(requested)
    trusted_set = MapSet.new(trusted)

    if Enum.all?(requested, &MapSet.member?(trusted_set, &1)) do
      :ok
    else
      {:error, {:credential_policy_allowlist_not_target_bound, :allowed_ports, requested}}
    end
  end

  defp trusted_hosts(%MonitoredService{} = service) do
    [
      service.host,
      uri_part(service.endpoint_url, :host)
    ]
    |> string_list()
    |> Enum.uniq()
  end

  defp trusted_paths(%MonitoredService{} = service) do
    [
      service.path,
      uri_part(service.endpoint_url, :path)
    ]
    |> string_list()
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp trusted_ports(%MonitoredService{} = service) do
    explicit_ports =
      [
        service.port,
        uri_part(service.endpoint_url, :port)
      ]
      |> integer_list()
      |> Enum.uniq()

    if_result =
      if explicit_ports == [] do
        [default_port(service.protocol)]
      else
        explicit_ports
      end

    if_result
    |> integer_list()
    |> Enum.uniq()
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port("postgres"), do: 5432
  defp default_port("postgresql"), do: 5432
  defp default_port("mysql"), do: 3306
  defp default_port("mssql"), do: 1433
  defp default_port("tcp"), do: nil
  defp default_port("tls"), do: nil
  defp default_port(_protocol), do: nil

  defp uri_part(nil, _part), do: nil
  defp uri_part("", _part), do: nil

  defp uri_part(value, part) when is_binary(value) do
    uri = URI.parse(value)
    Map.get(uri, part)
  rescue
    _ -> nil
  end

  defp normalize_path(nil), do: nil
  defp normalize_path(""), do: ""
  defp normalize_path(path) when is_binary(path) and binary_part(path, 0, 1) == "/", do: path
  defp normalize_path(path) when is_binary(path), do: "/" <> path

  defp grant_type(policy, binding, %MonitoredService{} = service, descriptor) do
    credential_requirements =
      descriptor |> Map.get("credential_requirements", %{}) |> normalize_map()

    string_value(policy, "grant_type") ||
      string_value(credential_requirements, "grant_type") ||
      default_grant_type(service) ||
      "#{binding.descriptor_id}.credential"
  end

  defp default_grant_type(%MonitoredService{service_kind: :http}), do: "http_auth"
  defp default_grant_type(%MonitoredService{service_kind: :database}), do: "database_auth"
  defp default_grant_type(%MonitoredService{service_kind: :tcp}), do: "tcp_auth"
  defp default_grant_type(%MonitoredService{service_kind: :tls}), do: "tls_auth"
  defp default_grant_type(_service), do: nil

  defp credential_purpose(policy, descriptor) do
    credential_requirements =
      descriptor |> Map.get("credential_requirements", %{}) |> normalize_map()

    string_value(policy, "purpose") ||
      string_value(credential_requirements, "purpose") ||
      "service_monitoring"
  end

  defp inject_policy(policy, %MonitoredService{} = service, descriptor) do
    credential_requirements =
      descriptor |> Map.get("credential_requirements", %{}) |> normalize_map()

    policy["inject"]
    |> normalize_map()
    |> case do
      inject when map_size(inject) > 0 ->
        inject

      _ ->
        credential_requirements["inject"]
        |> normalize_map()
        |> case do
          inject when map_size(inject) > 0 -> inject
          _ -> default_inject(service)
        end
    end
  end

  defp default_inject(%MonitoredService{service_kind: :http}), do: %{"type" => "http_auth"}

  defp default_inject(%MonitoredService{service_kind: :database}),
    do: %{"type" => "database_auth"}

  defp default_inject(%MonitoredService{service_kind: :tcp}), do: %{"type" => "tcp_auth"}
  defp default_inject(%MonitoredService{service_kind: :tls}), do: %{"type" => "tls_client_auth"}
  defp default_inject(_service), do: %{}

  defp grant_ids(grants) do
    grants
    |> Enum.map(&Map.get(&1, "grant_id"))
    |> Enum.reject(&ValueUtils.blank_string?/1)
  end

  defp maybe_secret_ref(nil), do: nil
  defp maybe_secret_ref(""), do: nil
  defp maybe_secret_ref(secret_id), do: SecretRefs.network_credential_ref(secret_id)

  defp resolution_location(policy) do
    case string_value(policy, "resolution_location") do
      "control_plane" -> :control_plane
      "hybrid" -> :hybrid
      _ -> :agent
    end
  end

  defp grantless_policy?(policy) do
    string_value(policy, "mode") in ["", "none", "disabled", "no_credentials"]
  end

  defp normalize_map(%{} = map), do: MapUtils.stringify_keys(map)
  defp normalize_map(_), do: %{}

  defp string_value(map, key), do: ValueUtils.string_value(map, [key])

  defp int_value(map, key, default), do: ValueUtils.int_value(map, [key], default)

  defp string_list(nil), do: []

  defp string_list(value) when is_list(value),
    do: value |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

  defp string_list(value), do: string_list([value])

  defp integer_list(nil), do: []

  defp integer_list(value) when is_list(value) do
    value
    |> Enum.map(&parse_integer/1)
    |> Enum.reject(&is_nil/1)
  end

  defp integer_list(value), do: integer_list([value])

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value

  defp test_grant_id, do: "test-monitoring-grant-#{System.unique_integer([:positive])}"
end
