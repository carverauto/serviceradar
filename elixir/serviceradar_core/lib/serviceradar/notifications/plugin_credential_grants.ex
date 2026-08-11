defmodule ServiceRadar.Notifications.PluginCredentialGrants do
  @moduledoc """
  Prepares the guest-visible channel configuration and host-only credential
  grants for one plugin-backed notification attempt.

  A notifier receives opaque `secretRef` sentinels in `channel_config`. The
  corresponding `CredentialBrokerGrant` payloads travel beside the request and
  are removed by the agent before `get_config`, so only the host can resolve
  and inject credential material.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Plugins.NotificationCredentialRequirement
  alias ServiceRadar.Plugins.SecretRefs

  @default_ttl_seconds 300

  @type prepared :: %{
          channel_config: map(),
          payload_fields: map(),
          context: map()
        }

  @spec prepare(map(), map(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(channel, target, opts \\ []) when is_map(channel) and is_map(target) do
    channel_config = channel_config(channel)
    requirements = normalize_map(Map.get(target, :credential_requirements))

    requirements
    |> Enum.sort_by(fn {name, _requirement} -> name end)
    |> Enum.reduce_while({:ok, []}, fn {name, requirement}, {:ok, grants} ->
      case issue_requirement(name, requirement, channel, target, channel_config, opts) do
        {:ok, nil} ->
          {:cont, {:ok, grants}}

        {:ok, grant} ->
          {:cont, {:ok, [grant | grants]}}

        {:error, reason} ->
          revoke_issued(grants, opts)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, grants} ->
        grants = Enum.reverse(grants)

        {:ok,
         %{
           channel_config: channel_config,
           payload_fields: grant_payload_fields(grants),
           context: %{credential_broker_grant_ids: grant_ids(grants)}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def issue_persisted_grant(attrs, opts \\ []) when is_map(attrs) do
    actor =
      Keyword.get(opts, :actor, SystemActor.system(:notification_plugin_credential_grants))

    attrs = CredentialBrokerGrant.issue_attrs(attrs)

    with {:ok, grant} <- CredentialBrokerGrant.issue_grant(attrs, actor: actor) do
      {:ok, CredentialBrokerGrant.to_payload(grant)}
    end
  end

  defp issue_requirement(name, requirement, channel, target, config, opts) do
    path = "notification credential requirement #{name}"

    case NotificationCredentialRequirement.normalize(requirement, path) do
      {:ok, requirement} ->
        with {:ok, inject} <- NotificationCredentialRequirement.to_inject(requirement, path),
             {:ok, targets} <- NotificationCredentialRequirement.targets(requirement, path) do
          issue_normalized_requirement(
            name,
            requirement,
            inject,
            targets,
            channel,
            target,
            config,
            opts
          )
        else
          {:error, errors} ->
            {:error, {:invalid_notification_credential_requirement, name, errors}}
        end

      {:error, errors} ->
        {:error, {:invalid_notification_credential_requirement, name, errors}}
    end
  end

  defp issue_normalized_requirement(
         name,
         requirement,
         inject,
         targets,
         channel,
         target,
         config,
         opts
       ) do
    case credential_ref(name, requirement, config) do
      nil ->
        if required?(requirement),
          do: {:error, {:missing_notification_credential, name}},
          else: {:ok, nil}

      ref ->
        with {:ok, secret_id} <- network_secret_id(ref, name),
             {:ok, allow} <- grant_allow(requirement, config, target, targets, name) do
          attrs =
            grant_attrs(
              name,
              requirement,
              inject,
              channel,
              target,
              ref,
              secret_id,
              allow,
              opts
            )

          issue_grant(attrs, opts)
        end
    end
  end

  defp issue_grant(attrs, opts) do
    issuer = Keyword.get(opts, :grant_issuer, &issue_persisted_grant/2)

    result =
      cond do
        is_function(issuer, 2) -> issuer.(attrs, opts)
        is_function(issuer, 1) -> issuer.(attrs)
        true -> {:error, :invalid_notification_grant_issuer}
      end

    case result do
      {:ok, %{} = grant} -> {:ok, grant}
      {:error, reason} -> {:error, {:notification_grant_issue_failed, name_for(attrs), reason}}
      other -> {:error, {:invalid_notification_grant_issuer_result, other}}
    end
  end

  defp grant_attrs(name, requirement, inject, channel, target, ref, secret_id, allow, opts) do
    channel_id = string_value(channel, :id)

    %{
      secret_id: secret_id,
      secret_ref: ref,
      grant_type: "notification_credential",
      consumer_kind: :plugin,
      consumer_id: string_value(target, :plugin_assignment_id),
      purpose: "notification:#{channel_id}:#{name}",
      target_kind: "notification_channel",
      target_id: channel_id,
      agent_id: string_value(target, :agent_uid),
      resolution_location: :agent,
      allowed_schemes: allow.schemes,
      allowed_methods: allow.methods,
      allowed_paths: allow.paths,
      allowed_hosts: allow.hosts,
      allowed_ports: allow.ports,
      inject: inject,
      metadata: %{
        "notification_delivery_id" => Keyword.get(opts, :delivery_id),
        "requirement_name" => name
      },
      ttl_seconds: positive_integer(Map.get(requirement, "ttl_seconds"), @default_ttl_seconds)
    }
  end

  defp grant_allow(requirement, config, target, targets, name) do
    allow = normalize_map(Map.get(requirement, "allow"))
    permissions = normalize_map(Map.get(target, :effective_permissions))
    effective_hosts = string_list(Map.get(permissions, "allowed_domains"))
    effective_ports = integer_list(Map.get(permissions, "allowed_ports"))

    result =
      if targets == [] do
        endpoint_grant_allow(allow, endpoint_scopes(config), effective_hosts, effective_ports)
      else
        exact_target_grant_allow(allow, targets, effective_hosts, effective_ports)
      end

    case result do
      {:ok, scoped} -> {:ok, scoped}
      :error -> {:error, {:notification_credential_scope_missing, name}}
    end
  end

  defp endpoint_grant_allow(allow, endpoints, effective_hosts, effective_ports) do
    requested_hosts = string_list(Map.get(allow, "hosts"))
    requested_ports = integer_list(Map.get(allow, "ports"))
    schemes = string_list(Map.get(allow, "schemes"))
    methods = string_list(Map.get(allow, "methods"))
    paths = string_list(Map.get(allow, "paths"))

    schemes =
      if schemes == [] do
        case Enum.map(endpoints, & &1.scheme) do
          [] -> ["https"]
          endpoint_schemes -> endpoint_schemes
        end
      else
        schemes
      end

    with {:ok, hosts} <- scoped_hosts(requested_hosts, endpoints, effective_hosts),
         {:ok, ports} <- scoped_ports(requested_ports, endpoints, effective_ports) do
      {:ok,
       %{
         hosts: Enum.uniq(hosts),
         schemes: Enum.uniq(schemes),
         methods: Enum.uniq(methods),
         paths: Enum.uniq(paths),
         ports: Enum.uniq(ports)
       }}
    end
  end

  # Form and password-grant modes carry an exact HTTPS request target. The OAuth
  # token exchange is an internal host request, so it does not participate in
  # the plugin-request grant lookup; validate it against effective permissions
  # here instead. Do not union its port into the request grant: allowed hosts and
  # ports are independent lists, and doing so would authorize their cross-product
  # (for example, the upstream host at the token endpoint's port).
  defp exact_target_grant_allow(allow, targets, effective_hosts, effective_ports) do
    request_targets = Enum.filter(targets, &(&1.kind == :request))
    request_hosts = request_targets |> Enum.map(& &1.host) |> Enum.uniq()
    request_ports = request_targets |> Enum.map(& &1.port) |> Enum.uniq()
    target_hosts = targets |> Enum.map(& &1.host) |> Enum.uniq()
    target_ports = targets |> Enum.map(& &1.port) |> Enum.uniq()
    request_schemes = request_targets |> Enum.map(& &1.scheme) |> Enum.uniq()
    request_methods = request_targets |> Enum.map(& &1.method) |> Enum.uniq()
    request_paths = request_targets |> Enum.map(& &1.path) |> Enum.uniq()

    with true <- effective_hosts != [] and effective_ports != [],
         true <- Enum.all?(target_hosts, &host_allowed?(&1, effective_hosts)),
         true <- Enum.all?(target_ports, &(&1 in effective_ports)),
         true <- requested_hosts_cover?(Map.get(allow, "hosts"), target_hosts),
         true <- requested_values_cover?(Map.get(allow, "ports"), target_ports),
         true <- requested_values_cover?(Map.get(allow, "schemes"), request_schemes),
         true <- requested_values_cover?(Map.get(allow, "methods"), request_methods),
         true <- requested_values_cover?(Map.get(allow, "paths"), request_paths) do
      {:ok,
       %{
         hosts: request_hosts,
         schemes: request_schemes,
         methods: request_methods,
         paths: request_paths,
         ports: request_ports
       }}
    else
      _other -> :error
    end
  end

  defp requested_hosts_cover?(nil, _required), do: true
  defp requested_hosts_cover?([], _required), do: true

  defp requested_hosts_cover?(requested, required) do
    requested = string_list(requested)
    Enum.all?(required, &host_allowed?(&1, requested))
  end

  defp requested_values_cover?(nil, _required), do: true
  defp requested_values_cover?([], _required), do: true

  defp requested_values_cover?(requested, required) do
    requested = List.wrap(requested)
    Enum.all?(required, &(&1 in requested))
  end

  # A credential grant is a second authority layered under the assignment's
  # egress permissions. It may equal or narrow that scope, but must never use a
  # notifier-authored requirement to widen it. When the channel names a concrete
  # endpoint, a wildcard assignment scope can safely be narrowed to that host;
  # without an endpoint, wildcard-only scopes fail closed because grants use an
  # exact-host allowlist.
  defp scoped_hosts(requested, endpoints, effective) do
    cond_result =
      cond do
        requested != [] -> requested
        endpoints != [] -> Enum.map(endpoints, & &1.host)
        true -> Enum.reject(effective, &wildcard_host?/1)
      end

    candidates =
      cond_result
      |> Enum.map(&normalize_host/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if candidates != [] and effective != [] and
         Enum.all?(candidates, &(concrete_host?(&1) and host_allowed?(&1, effective))) do
      {:ok, candidates}
    else
      :error
    end
  end

  defp scoped_ports(requested, endpoints, effective) do
    cond_result =
      cond do
        requested != [] -> requested
        endpoints != [] -> Enum.map(endpoints, & &1.port)
        true -> effective
      end

    candidates = Enum.uniq(cond_result)

    if candidates != [] and effective != [] and Enum.all?(candidates, &(&1 in effective)) do
      {:ok, candidates}
    else
      :error
    end
  end

  defp host_allowed?(host, effective) do
    host = normalize_host(host)

    Enum.any?(effective, fn entry ->
      entry = normalize_host(entry)

      cond do
        entry == "*" ->
          true

        String.starts_with?(entry, "*.") ->
          base = String.trim_leading(entry, "*.")
          host == base or String.ends_with?(host, "." <> base)

        true ->
          host == entry
      end
    end)
  end

  defp concrete_host?(host), do: host != "" and not wildcard_host?(host)
  defp wildcard_host?(host), do: String.contains?(to_string(host), "*")

  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp endpoint_scopes(config) do
    config
    |> Enum.flat_map(fn {key, value} ->
      if endpoint_key?(key) and is_binary(value) do
        case URI.parse(String.trim(value)) do
          %URI{scheme: scheme, host: host, port: port}
          when scheme in ["http", "https"] and is_binary(host) and host != "" ->
            [%{scheme: scheme, host: normalize_host(host), port: port || default_port(scheme)}]

          _other ->
            []
        end
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp endpoint_key?(key) do
    key = key |> to_string() |> String.downcase()
    String.contains?(key, "url") or String.contains?(key, "endpoint")
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp credential_ref(name, requirement, config) do
    explicit_key = Map.get(requirement, "config_key")

    [explicit_key, name, name <> "_secret_ref", name <> "_ref"]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn key ->
      case Map.get(config, to_string(key)) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp network_secret_id(ref, name) do
    case SecretRefs.network_credential_ref_id(ref) do
      {:ok, secret_id} -> {:ok, secret_id}
      {:error, _reason} -> {:error, {:unsupported_notification_secret_ref, name}}
    end
  end

  defp channel_config(channel) do
    channel
    |> Map.get(:config, %{})
    |> normalize_map()
    |> Map.merge(SecretRefs.public_params(Map.get(channel, :secret_refs, %{})))
  end

  defp grant_payload_fields([]), do: %{}
  defp grant_payload_fields(grants), do: %{"credential_brokers" => grants}

  defp grant_ids(grants) do
    grants
    |> Enum.map(&Map.get(&1, "grant_id"))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp revoke_issued([], _opts), do: :ok

  defp revoke_issued(grants, opts) do
    revoker = Keyword.get(opts, :grant_revoker, &revoke_persisted/1)

    Enum.each(grant_ids(grants), fn grant_id ->
      if is_function(revoker, 1), do: revoker.(grant_id)
    end)
  end

  defp revoke_persisted(grant_id) do
    actor = SystemActor.system(:notification_plugin_credential_grants_cleanup)

    with {:ok, grant} <- CredentialBrokerGrant.get_by_id(grant_id, actor: actor),
         true <- Map.get(grant, :status) in [:issued, :active] do
      _ =
        CredentialBrokerGrant.revoke(grant, %{reason: "notification_grant_batch_failed"},
          actor: actor
        )
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp required?(requirement), do: Map.get(requirement, "required") == true

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), item} end)
  end

  defp normalize_map(_value), do: %{}

  defp string_list(values) do
    values
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) or is_atom(&1)))
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp integer_list(values), do: values |> List.wrap() |> Enum.filter(&is_integer/1)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp string_value(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp name_for(attrs) do
    attrs
    |> Map.get(:metadata, %{})
    |> Map.get("requirement_name", "credential")
  end
end
