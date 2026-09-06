defmodule ServiceRadar.Plugins.ProxmoxHostAuthority do
  @moduledoc """
  Builds the trusted host-side authority envelope for Proxmox Wasm assignments.

  Credential-broker grants and secret references are never returned in the
  public params consumed by Wasm. The plugin receives only a sentinel while the
  agent host retains a broker grant bound to one exact controller origin and a
  finite set of target identity fields.
  """

  require Logger

  @schema "serviceradar.plugin_host_authority.v1"
  @provider "proxmox"
  @inventory_plugin_id "proxmox-inventory"
  @inventory_entrypoint "run_check"
  @console_plugin_id "proxmox-console"
  @console_entrypoint "run_console"
  @host_credential_sentinel "__SERVICERADAR_HOST_CREDENTIAL__"
  @assignment_policy_fingerprint_domain "serviceradar.proxmox.assignment-policy.v1"
  @ssh_host_key_policies ~w(known_hosts trust_on_first_use)

  @broker_schemas MapSet.new([
                    "serviceradar.edge_credential_broker_grant.v1",
                    "serviceradar.edge_credential_broker_grant.v2"
                  ])

  @secret_keys MapSet.new(~w(
                 credential_broker
                 api_token_secret_ref
                 credential_secret
                 credential_secret_ref
                 password_secret_ref
                 api_key_secret_ref
                 _secret_material
                 _serviceradar
                 _serviceradar_host_credentials
                 api_token
                 password
                 private_key
                 passphrase
                 token
                 bearer_token
                 authorization
                 proxy-authorization
                 cookie
                 csrf
                 ticket
                 insecure_skip_verify
                 ssh_host_key_policy
                 ca_bundle_pem
                 server_cert_fingerprint
               ))

  @target_id_keys ~w(
    device_uid integration_id controller_id
    provider_ref provider_instance_ref native_cluster_id object_kind native_object_id
    node cluster vmid target_kind controller_device_uid controller_provider_ref
  )
  @grant_keys ~w(schema grant_id grant_type credential_rule_id credential_secret_ref consumer target resolution_location inject cache allow ttl_seconds expires_at)

  @spec assignment?(term(), term()) :: boolean()
  def assignment?(@inventory_plugin_id, @inventory_entrypoint), do: true
  def assignment?(@console_plugin_id, @console_entrypoint), do: true
  def assignment?(_plugin_id, _entrypoint), do: false

  @spec partition(String.t(), String.t(), map(), term()) :: {map(), map() | nil}
  def partition(plugin_id, entrypoint, params, assignment_id)
      when is_map(params) and is_binary(plugin_id) and is_binary(entrypoint) do
    if assignment?(plugin_id, entrypoint) do
      params = stringify_keys(params)
      grant = broker_grant(params)
      auth_mode = auth_mode(plugin_id, params, grant)
      public_params = public_params(plugin_id, params, auth_mode)

      host_params =
        with %{} = grant <- grant,
             {:ok, policy_binding} <-
               assignment_policy_binding(plugin_id, entrypoint, params, assignment_id),
             {:ok, ssh_host_key_policy} <- ssh_host_key_policy(auth_mode, params) do
          bindings =
            build_bindings(
              plugin_id,
              params,
              grant,
              auth_mode,
              assignment_id,
              policy_binding,
              ssh_host_key_policy
            )

          if bindings == [] do
            Logger.warning(
              "Proxmox host authority: no bindings built for assignment " <>
                "#{inspect(assignment_id)} (plugin=#{plugin_id}); the assignment will be " <>
                "skipped as :proxmox_host_authority_unavailable"
            )

            nil
          else
            %{"schema" => @schema, "bindings" => bindings}
          end
        else
          # Returning a bare nil is what makes :proxmox_host_authority_unavailable
          # uninformative upstream: it can mean no broker grant, a policy-binding
          # failure, or an SSH host-key-policy failure. Same control flow as the
          # `_ -> nil` this replaces; the value is now named and logged.
          other ->
            Logger.warning(
              "Proxmox host authority: host binding unavailable for assignment " <>
                "#{inspect(assignment_id)} (plugin=#{plugin_id}): #{inspect(other)}"
            )

            nil
        end

      {public_params, host_params}
    else
      {params, nil}
    end
  end

  def partition(_plugin_id, _entrypoint, params, _assignment_id),
    do: {if(is_map(params), do: params, else: %{}), nil}

  @doc false
  @spec public_params(String.t(), map()) :: map()
  def public_params(plugin_id, params) when is_binary(plugin_id) and is_map(params) do
    params = stringify_keys(params)
    public_params(plugin_id, params, auth_mode(plugin_id, params, broker_grant(params)))
  end

  @doc false
  @spec public_params(String.t(), map(), :api_token | :ssh) :: map()
  def public_params(plugin_id, params, auth_mode)
      when is_binary(plugin_id) and is_map(params) and auth_mode in [:api_token, :ssh] do
    params = stringify_keys(params)
    credential_rule_id = value(broker_grant(params) || %{}, "credential_rule_id")
    params = sanitize_value(params)
    sentinel_key = if auth_mode == :ssh, do: "credential_secret", else: "api_token"

    params =
      if is_map(Map.get(params, "template")) do
        params
        |> update_in(["template"], &Map.put(&1, sentinel_key, @host_credential_sentinel))
        |> put_target_sentinels(plugin_id, auth_mode)
      else
        params
        |> Map.put(sentinel_key, @host_credential_sentinel)
        |> put_target_sentinels(plugin_id, auth_mode)
      end

    if present?(credential_rule_id) do
      Map.put_new(params, "credential_rule_id", credential_rule_id)
    else
      params
    end
  end

  defp put_target_sentinels(params, @inventory_plugin_id, :api_token) do
    case Map.get(params, "targets") do
      targets when is_list(targets) ->
        Map.put(
          params,
          "targets",
          Enum.map(targets, fn
            %{} = target -> Map.put(target, "api_token", @host_credential_sentinel)
            target -> target
          end)
        )

      _ ->
        params
    end
  end

  defp put_target_sentinels(params, _plugin_id, _auth_mode), do: params

  @doc "Returns the immutable policy binding shared by config delivery and console sessions."
  @spec assignment_policy_binding(String.t(), String.t(), map(), String.t()) ::
          {:ok,
           %{
             policy_id: String.t(),
             policy_version: pos_integer(),
             credential_rule_id: String.t(),
             fingerprint: String.t()
           }}
          | {:error, term()}
  def assignment_policy_binding(plugin_id, entrypoint, params, assignment_id)
      when is_binary(plugin_id) and is_binary(entrypoint) and is_map(params) and
             is_binary(assignment_id) do
    params = stringify_keys(params)
    grant = broker_grant(params) || %{}

    credential_rule_id =
      first_string([
        value(params, "credential_rule_id"),
        value(map_value(params, "template"), "credential_rule_id"),
        value(grant, "credential_rule_id")
      ])

    policy_id = value(params, "policy_id")
    policy_version = value(params, "policy_version")

    expected_policy_ids =
      case {plugin_id, entrypoint, credential_rule_id} do
        {@inventory_plugin_id, @inventory_entrypoint, rule_id} when is_binary(rule_id) ->
          # BOTH forms, because the writer emits the unsuffixed one.
          # PluginAssignmentMaterializer.policy_id_for_rule/2 special-cases
          # inventory_enrichment to "network-credential-rule:<rule>" to preserve
          # the original inventory policy id for upgrade compatibility. Accepting
          # only the suffixed form meant every materialized inventory assignment
          # failed this binding and was skipped at config generation -- the plugin
          # was never delivered, and the only symptom was a warning.
          [
            "network-credential-rule:#{rule_id}",
            "network-credential-rule:#{rule_id}:inventory_enrichment"
          ]

        {@console_plugin_id, @console_entrypoint, rule_id} when is_binary(rule_id) ->
          ["network-credential-rule:#{rule_id}:console_access"]

        _other ->
          []
      end

    if present?(assignment_id) and present?(credential_rule_id) and
         policy_id in expected_policy_ids and is_integer(policy_version) and policy_version > 0 do
      canonical =
        Enum.join(
          [
            @assignment_policy_fingerprint_domain,
            assignment_id,
            plugin_id,
            entrypoint,
            policy_id,
            Integer.to_string(policy_version),
            credential_rule_id
          ],
          "\n"
        )

      {:ok,
       %{
         policy_id: policy_id,
         policy_version: policy_version,
         credential_rule_id: credential_rule_id,
         fingerprint:
           :sha256
           |> :crypto.hash(canonical)
           |> Base.encode16(case: :lower)
       }}
    else
      {:error, :invalid_assignment_policy_binding}
    end
  end

  def assignment_policy_binding(_plugin_id, _entrypoint, _params, _assignment_id),
    do: {:error, :invalid_assignment_policy_binding}

  defp build_bindings(
         plugin_id,
         params,
         grant,
         auth_mode,
         assignment_id,
         policy_binding,
         ssh_host_key_policy
       ) do
    credential_rule_id =
      first_string([
        value(params, "credential_rule_id"),
        value(map_value(params, "template"), "credential_rule_id"),
        value(grant, "credential_rule_id")
      ])

    params
    |> binding_targets(plugin_id)
    |> Enum.map(fn target ->
      with rule_id when is_binary(rule_id) <- credential_rule_id,
           {:ok, origin} <- target_origin(plugin_id, target, params, auth_mode),
           target_ids when map_size(target_ids) > 0 <-
             target |> target_ids() |> binding_target_ids(plugin_id) do
        binding_grant = scope_grant_to_origin(grant, origin, plugin_id, auth_mode, target)

        %{
          "binding_id" => binding_id(assignment_id, credential_rule_id, origin, target_ids),
          "provider" => @provider,
          "credential_rule_id" => rule_id,
          "origin" => origin,
          "assignment_policy_version" => policy_binding.policy_version,
          "assignment_policy_fingerprint" => policy_binding.fingerprint,
          "credential_broker" => binding_grant,
          "target_ids" => target_ids
        }
        |> maybe_put("ssh_host_key_policy", ssh_host_key_policy)
        |> maybe_put("ca_bundle_pem", ca_bundle_pem(params))
        |> maybe_put("server_cert_fingerprint", server_cert_fingerprint(params))
      else
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn binding ->
      {binding["origin"], binding["credential_rule_id"], binding["target_ids"]}
    end)
    |> single_origin_fingerprint(server_cert_fingerprint(params), plugin_id, assignment_id)
  end

  # A cluster CA signs every node leaf, so one ca_bundle_pem legitimately anchors
  # every target. A server_cert_fingerprint names one certificate, and therefore
  # one host: stamped across sibling origins it yields anchors that can only ever
  # fail the handshake. Refuse the assignment and name the remedy instead of
  # shipping bindings that are known-broken for every origin but the first.
  defp single_origin_fingerprint(bindings, nil, _plugin_id, _assignment_id), do: bindings

  defp single_origin_fingerprint(bindings, _fingerprint, plugin_id, assignment_id) do
    origins = bindings |> Enum.map(& &1["origin"]) |> Enum.uniq()

    if length(origins) > 1 do
      Logger.warning(
        "Proxmox host authority: server_cert_fingerprint pins a single certificate but " <>
          "assignment #{inspect(assignment_id)} (plugin=#{plugin_id}) resolves to " <>
          "#{length(origins)} origins (#{Enum.join(origins, ", ")}); pin the cluster CA " <>
          "with ca_bundle_pem to cover every node"
      )

      []
    else
      bindings
    end
  end

  defp binding_targets(params, plugin_id) do
    input_items =
      params
      |> list_value("inputs")
      |> Enum.flat_map(fn input -> list_value(input, "items") end)
      |> Enum.filter(&is_map/1)

    direct_targets = params |> list_value("targets") |> Enum.filter(&is_map/1)

    targets = input_items ++ direct_targets

    if targets == [] do
      template = map_value(params, "template")
      direct = Map.merge(params, template)

      if target_candidate?(plugin_id, direct), do: [direct], else: []
    else
      targets
    end
  end

  defp target_candidate?(@inventory_plugin_id, target) do
    Enum.any?(
      ~w(base_url proxmox_base_url management_url endpoint ip device_ip hostname name),
      &present?(value(target, &1))
    )
  end

  defp target_candidate?(@console_plugin_id, target) do
    explicit_controller?(target) or pve_host_target?(target)
  end

  defp target_candidate?(_plugin_id, _target), do: false

  defp target_origin(@inventory_plugin_id, target, params, _auth_mode) do
    candidate =
      first_string([
        controller_value(target, "base_url"),
        controller_value(target, "proxmox_base_url"),
        controller_value(target, "pve_base_url"),
        controller_value(target, "controller_url"),
        controller_value(target, "management_url"),
        controller_value(target, "endpoint"),
        controller_value(target, "ip"),
        controller_value(target, "device_ip"),
        controller_value(target, "hostname"),
        controller_value(target, "name"),
        controller_value(map_value(params, "template"), "base_url"),
        controller_value(params, "base_url")
      ])

    canonical_origin(candidate, :proxmox_api, target)
  end

  defp target_origin(@console_plugin_id, target, params, :api_token) do
    candidate =
      first_string([
        controller_value(target, "proxmox_base_url"),
        controller_value(target, "pve_base_url"),
        controller_value(target, "controller_url"),
        controller_value(target, "management_url"),
        controller_value(target, "base_url"),
        pve_host_value(target, "ip"),
        pve_host_value(target, "device_ip"),
        pve_host_value(target, "hostname"),
        controller_value(map_value(params, "template"), "base_url"),
        controller_value(params, "base_url")
      ])

    canonical_origin(candidate, :proxmox_api, target)
  end

  defp target_origin(@console_plugin_id, target, params, :ssh) do
    candidate =
      first_string([
        controller_value(target, "proxmox_base_url"),
        controller_value(target, "pve_base_url"),
        controller_value(target, "controller_url"),
        controller_value(target, "management_url"),
        controller_value(target, "base_url"),
        pve_host_value(target, "ip"),
        pve_host_value(target, "device_ip"),
        pve_host_value(target, "hostname"),
        controller_value(map_value(params, "template"), "base_url"),
        controller_value(params, "base_url")
      ])

    # The binding identity remains the canonical PVE controller origin for both
    # native and SSH console modes. The trusted SSH connector derives the same
    # controller host and intersects it with the grant's exact port-22 ACL.
    canonical_origin(candidate, :proxmox_api, target)
  end

  defp target_origin(_plugin_id, _target, _params, _auth_mode), do: {:error, :invalid_target}

  defp canonical_origin(value, mode, target) when is_binary(value) do
    value = String.trim(value)

    default_scheme = if mode == :ssh, do: "ssh", else: "https"
    default_port = if mode == :ssh, do: int_value(target, "ssh_port") || 22, else: 8006
    explicit_scheme? = String.contains?(value, "://")
    candidate = if explicit_scheme?, do: value, else: "#{default_scheme}://#{value}"
    uri = URI.parse(candidate)

    allowed_schemes = if mode == :ssh, do: ["ssh"], else: ["https"]
    port = if explicit_scheme?, do: uri.port, else: explicit_port(uri.authority) || default_port

    cond do
      value == "" ->
        {:error, :missing_origin}

      uri.scheme not in allowed_schemes ->
        {:error, :invalid_origin_scheme}

      not present?(uri.host) or present?(uri.userinfo) or present?(uri.query) or
          present?(uri.fragment) ->
        {:error, :invalid_origin_host}

      not valid_ip_literal?(uri.host) ->
        {:error, :invalid_origin_host}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, :invalid_origin_port}

      not valid_origin_authority?(uri.authority, uri.host, port) ->
        {:error, :invalid_origin_port}

      true ->
        scheme = String.downcase(uri.scheme)
        host = uri.host |> String.downcase() |> String.trim_trailing(".")

        if host == "" or String.contains?(host, "%") do
          {:error, :invalid_origin_host}
        else
          authority =
            if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"

          origin = "#{scheme}://#{authority}"
          {:ok, origin}
        end
    end
  end

  defp canonical_origin(_value, _mode, _target), do: {:error, :missing_origin}

  defp valid_origin_authority?(authority, host, port)
       when is_binary(authority) and is_binary(host) and is_integer(port) do
    authority = String.downcase(authority)
    host = String.downcase(host)

    allowed =
      if String.contains?(host, ":") do
        ["[#{host}]", "[#{host}]:#{port}"]
      else
        [host, "#{host}:#{port}"]
      end

    authority in allowed
  end

  defp valid_origin_authority?(_authority, _host, _port), do: false

  defp valid_ip_literal?(host) when is_binary(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    not String.contains?(host, "%") and
      match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_ip_literal?(_host), do: false

  defp explicit_port(authority) when is_binary(authority) do
    case Regex.run(~r/(?:\]|[^:]):(\d+)\z/, authority) do
      [_, raw_port] ->
        case Integer.parse(raw_port) do
          {port, ""} -> port
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp explicit_port(_authority), do: nil

  defp scope_grant_to_origin(grant, origin, plugin_id, auth_mode, target) do
    grant = Map.take(grant, @grant_keys)
    uri = URI.parse(origin)
    allow = map_value(grant, "allow")
    inject = map_value(grant, "inject")

    allow =
      allow
      |> Map.put("hosts", [String.downcase(uri.host)])
      |> Map.put("ports", if(auth_mode == :ssh, do: [22], else: [uri.port]))
      |> maybe_put_console_allow(plugin_id, auth_mode, target)

    inject =
      if auth_mode == :api_token do
        inject
        |> Map.put("type", "http_header")
        |> Map.put("name", "Authorization")
        |> Map.put("scheme", "PVEAPIToken")
      else
        inject
      end

    grant
    |> Map.put("allow", allow)
    |> Map.put("inject", inject)
  end

  defp maybe_put_console_allow(allow, @console_plugin_id, :api_token, target) do
    paths =
      if target_ids(target)["target_kind"] == "pve_host" do
        # One controller-scoped assignment serves the guests authoritatively
        # owned by that PVE. The trusted streaming connector derives and
        # enforces the exact guest path from the immutable session; no wildcard
        # grant path is introduced here.
        []
      else
        exact_console_paths(target)
      end

    case paths do
      [] ->
        allow
        |> Map.put("methods", ["GET", "POST"])
        |> Map.put("paths", [])

      paths ->
        allow
        |> Map.put("methods", ["GET", "POST"])
        |> Map.put("paths", paths)
    end
  end

  defp maybe_put_console_allow(allow, @console_plugin_id, :ssh, _target) do
    allow
    |> Map.put("methods", [])
    |> Map.put("paths", [])
  end

  defp maybe_put_console_allow(allow, _plugin_id, _auth_mode, _target), do: allow

  defp binding_target_ids(%{"target_kind" => "pve_host"} = ids, @console_plugin_id) do
    # This binding identifies the controller, not the eventual guest subject.
    # The session carries separate controller_* and guest identity fields.
    Map.drop(ids, [
      "target_kind",
      "vmid",
      "controller_device_uid",
      "controller_provider_ref"
    ])
  end

  defp binding_target_ids(ids, _plugin_id), do: ids

  defp exact_console_paths(target) do
    ids = target_ids(target)
    node = path_segment(ids["node"])
    vmid = ids["vmid"]

    case {node, vmid, ids["target_kind"]} do
      {node, _vmid, "pve_host"} when is_binary(node) ->
        [
          "/api2/json/nodes/#{node}/termproxy",
          "/api2/json/nodes/#{node}/vncwebsocket"
        ]

      {node, vmid, "lxc_guest"} when is_binary(node) and is_binary(vmid) ->
        vmid = path_segment(vmid)

        [
          "/api2/json/nodes/#{node}/lxc/#{vmid}/termproxy",
          "/api2/json/nodes/#{node}/lxc/#{vmid}/vncwebsocket"
        ]

      {node, vmid, "qemu_guest"} when is_binary(node) and is_binary(vmid) ->
        vmid = path_segment(vmid)

        [
          "/api2/json/nodes/#{node}/qemu/#{vmid}/vncproxy",
          "/api2/json/nodes/#{node}/qemu/#{vmid}/vncwebsocket"
        ]

      _ ->
        []
    end
  end

  defp path_segment(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: URI.encode(value, &URI.char_unreserved?/1)
  end

  defp path_segment(_value), do: nil

  defp auth_mode(@inventory_plugin_id, _params, _grant), do: :api_token

  defp auth_mode(@console_plugin_id, params, grant) do
    auth_method = value(grant, "auth_method")
    template = map_value(params, "template")

    cond do
      auth_method == "proxmox_api_token" -> :api_token
      present?(value(params, "api_token_secret_ref")) -> :api_token
      present?(value(template, "api_token_secret_ref")) -> :api_token
      value(params, "api_token") == @host_credential_sentinel -> :api_token
      value(template, "api_token") == @host_credential_sentinel -> :api_token
      true -> :ssh
    end
  end

  defp auth_mode(_plugin_id, _params, _grant), do: :api_token

  # Operator-supplied trust material, delivered by the manifest params template
  # as $source: rule. The agent verifies against this anchor alone; it never
  # reaches the Wasm guest (see @secret_keys).
  defp ca_bundle_pem(params) do
    first_string([
      value(map_value(params, "template"), "ca_bundle_pem"),
      value(params, "ca_bundle_pem")
    ])
  end

  defp server_cert_fingerprint(params) do
    first_string([
      value(map_value(params, "template"), "server_cert_fingerprint"),
      value(params, "server_cert_fingerprint")
    ])
  end

  defp ssh_host_key_policy(:api_token, _params), do: {:ok, nil}

  defp ssh_host_key_policy(:ssh, params) do
    candidates =
      [
        value(map_value(params, "template"), "ssh_host_key_policy"),
        value(params, "ssh_host_key_policy")
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case candidates do
      [policy] when policy in @ssh_host_key_policies -> {:ok, policy}
      _ -> {:error, :invalid_ssh_host_key_policy}
    end
  end

  defp ssh_host_key_policy(_auth_mode, _params), do: {:error, :invalid_ssh_host_key_policy}

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp broker_grant(params) do
    grant =
      case value(params, "credential_broker") do
        %{} = value -> value
        _ -> value(map_value(params, "template"), "credential_broker")
      end

    case grant do
      %{} = grant ->
        grant = stringify_keys(grant)
        if MapSet.member?(@broker_schemas, value(grant, "schema")), do: grant

      _ ->
        nil
    end
  end

  defp target_ids(target) do
    provider_ref =
      first_string([
        controller_value(target, "provider_ref"),
        controller_value(target, "hypervisor_provider_ref"),
        controller_value(target, "target_ref")
      ])

    parsed_ref = parse_provider_ref(provider_ref)

    %{
      "device_uid" =>
        first_string([
          controller_value(target, "device_uid"),
          controller_value(target, "uid"),
          controller_value(target, "device_id")
        ]),
      "integration_id" => controller_value(target, "integration_id"),
      "controller_id" => controller_value(target, "controller_id"),
      "provider_ref" => provider_ref,
      "provider_instance_ref" => controller_value(target, "provider_instance_ref"),
      "native_cluster_id" => controller_value(target, "native_cluster_id"),
      "object_kind" => controller_value(target, "object_kind"),
      "native_object_id" => controller_value(target, "native_object_id"),
      "node" => first_string([controller_value(target, "node"), parsed_ref["node"]]),
      "cluster" => first_string([controller_value(target, "cluster"), parsed_ref["cluster"]]),
      "vmid" => first_string([controller_value(target, "vmid"), parsed_ref["vmid"]]),
      "target_kind" =>
        first_string([controller_value(target, "target_kind"), parsed_ref["target_kind"]]),
      "controller_device_uid" => controller_value(target, "controller_device_uid"),
      "controller_provider_ref" => controller_value(target, "controller_provider_ref")
    }
    |> Map.take(@target_id_keys)
    |> Enum.reject(fn {_key, id} -> not present?(id) end)
    |> Map.new(fn {key, id} -> {key, String.trim(to_string(id))} end)
  end

  defp parse_provider_ref(value) when is_binary(value) do
    case String.split(String.trim(value), ":") do
      ["proxmox", "guest", node, kind, vmid] ->
        %{
          "node" => node,
          "vmid" => vmid,
          "target_kind" => if(kind in ["lxc", "container"], do: "lxc_guest", else: "qemu_guest")
        }

      ["proxmox", "node", node] ->
        %{"node" => node, "target_kind" => "pve_host"}

      ["proxmox", "v2", cluster, kind, identity] when kind in ["vm", "qemu", "lxc"] ->
        %{
          "cluster" => cluster,
          "vmid" => identity,
          "target_kind" => if(kind == "lxc", do: "lxc_guest", else: "qemu_guest")
        }

      ["proxmox", "v2", cluster, "node", node] ->
        %{"cluster" => cluster, "node" => node, "target_kind" => "pve_host"}

      _ ->
        %{}
    end
  end

  defp parse_provider_ref(_value), do: %{}

  defp binding_id(assignment_id, credential_rule_id, origin, target_ids) do
    canonical_target_ids =
      target_ids
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("|", fn {key, value} -> "#{key}=#{value}" end)

    digest =
      [to_string(assignment_id), credential_rule_id || "", origin, canonical_target_ids]
      |> Enum.join("|")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "proxmox-#{digest}"
  end

  defp explicit_controller?(target) do
    Enum.any?(
      ~w(proxmox_base_url pve_base_url controller_url management_url base_url ssh_origin ssh_host),
      &present?(controller_value(target, &1))
    )
  end

  defp pve_host_target?(target) do
    target_kind = controller_value(target, "target_kind")
    device_role = controller_value(target, "device_role")
    provider_ref = controller_value(target, "provider_ref")

    target_kind in ["pve_host", "hypervisor", "node"] or device_role == "hypervisor" or
      (is_binary(provider_ref) and String.starts_with?(provider_ref, "proxmox:node:"))
  end

  defp pve_host_value(target, key) do
    if pve_host_target?(target), do: controller_value(target, key)
  end

  defp controller_value(map, key) when is_map(map) do
    metadata = map_value(map, "metadata")
    labels = map_value(map, "labels")
    first_string([value(map, key), value(metadata, key), value(labels, key)])
  end

  defp controller_value(_map, _key), do: nil

  defp sanitize_value(%{} = map) do
    map
    |> stringify_keys()
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@secret_keys, String.downcase(key)) end)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value)} end)
  end

  defp sanitize_value(list) when is_list(list), do: Enum.map(list, &sanitize_value/1)
  defp sanitize_value(value), do: value

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp map_value(map, key) do
    case value(map, key) do
      %{} = result -> result
      _ -> %{}
    end
  end

  defp list_value(map, key) do
    case value(map, key) do
      result when is_list(result) -> result
      _ -> []
    end
  end

  defp int_value(map, key) do
    case value(map, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp value(_map, _key), do: nil

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      _ ->
        nil
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_value), do: false
end
