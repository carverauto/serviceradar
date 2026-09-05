defmodule ServiceRadar.Plugins.IntegrationDescriptor do
  @moduledoc """
  Validates declarative integration metadata shipped in a signed plugin package.

  Descriptors let approved packages publish credential-provider and inventory-source
  metadata without loading provider-specific code into ServiceRadar. Core consumes
  only this bounded, validated data and the package's JSON configuration schema.
  """

  alias ServiceRadar.Credentials.CredentialParameterTemplate
  alias ServiceRadar.Plugins.MapUtils

  @allowed_root_keys ~w(documentation credential_profiles inventory_sources)
  @allowed_profile_keys ~w(
    provider label description auth_methods purposes scope_types provisioning
    rule_defaults rule_controls default supports_rules
  )
  @allowed_auth_method_keys ~w(
    id label description credential_kind fields payload tls_policies ssh_host_key_policies
  )
  @allowed_credential_field_keys ~w(
    id label description control required secret public min_length max_length placeholder default
  )
  @allowed_payload_keys ~w(format field template username_field)
  @allowed_provisioning_keys ~w(mode schedule_id credential_requirement consumers)
  @allowed_consumer_keys ~w(
    purpose plugin_id auth_methods constraints failure_mode grant params
    target_cardinality
  )
  @allowed_constraint_keys ~w(tls_policies ssh_host_key_policies)
  @allowed_grant_keys ~w(grant_type resolution_location inject allow ttl_seconds payload)
  @allowed_grant_allow_keys ~w(methods paths hosts ports)
  @allowed_rule_default_keys ~w(
    auth_method purposes target_query scope_type allowed_ports tls_policy ssh_host_key_policy
    credential_use_roles auto_discovery_enabled controller_host
  )
  @allowed_rule_control_keys ~w(
    allowed_ports auto_discovery_enabled controller_host target_query transport
  )
  @allowed_inventory_source_keys ~w(source label description metadata_fields emitted_facts)
  @forbidden_authority_keys ~w(
    fact_authority authority precedence winner winners wins canonical_priority
    authoritative
  )
  @allowed_metadata_field_keys ~w(key label description format)
  @allowed_documentation_keys ~w(title path url)

  @allowed_credential_kinds ~w(api_token username_password ssh_private_key certificate snmp opaque)
  @allowed_credential_controls ~w(text password textarea)
  @allowed_payload_formats ~w(scalar json template)
  @allowed_provisioning_modes ~w(credential_only producer_schedule target_policy)
  @allowed_failure_modes ~w(error skip)
  # How a consumer's work maps onto the rule's resolved targets.
  #
  # `per_target` (the default) means every resolved target is work: the
  # planner chunks them and each chunk becomes its own assignment, so a
  # controller-per-device integration (unifi-protect, proxmox) polls only its
  # own chunk.
  #
  # `single` means the work is the *rule*, not the targets: the endpoint comes
  # from the rule's controller host and one run covers the whole instance.
  # Chunking such a consumer runs the same whole-instance job once per chunk.
  # The planner therefore emits exactly one un-chunked assignment per
  # (rule, agent) for these, and `validate_single_cardinality_scope_types/4`
  # below keeps the (rule, agent) pair from multiplying across agents.
  @allowed_target_cardinalities ~w(per_target single)
  @allowed_resolution_locations ~w(control_plane agent hybrid)
  @allowed_tls_policies ~w(verify skip_verify)
  @allowed_ssh_host_key_policies ~w(known_hosts trust_on_first_use skip_verify)
  @allowed_http_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @allowed_injection_types ~w(
    http_header header bearer_token basic_auth http_basic_auth query query_param http_query
    form_urlencoded oauth2_password_bearer oauth2_client_credentials
  )
  @allowed_scope_types ~w(agent gateway partition)
  @allowed_field_formats ~w(text boolean number timestamp)
  @id_regex ~r/^[a-z0-9][a-z0-9_.-]{0,127}$/
  @metadata_key_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @max_description_bytes 2_048
  @max_documentation_url_bytes 2_048
  @max_label_bytes 120
  @max_profiles 16
  @max_credential_fields 16
  @max_credential_field_bytes 16_384
  @max_consumers 32
  @max_grant_entries 64
  @max_path_bytes 1_024
  @max_sources 16
  @max_metadata_fields 64

  @type descriptor :: %{String.t() => map() | [map()]}

  @spec validate(term(), [map()]) :: {:ok, descriptor()} | {:error, [String.t()]}
  def validate(nil, _producer_schedules), do: {:ok, empty()}

  def validate(value, producer_schedules) when is_map(value) and is_list(producer_schedules) do
    descriptor = MapUtils.stringify_keys(value)
    schedule_by_id = Map.new(producer_schedules, &{Map.get(&1, "schedule_id"), &1})

    errors =
      forbidden_authority_errors(descriptor, "integrations") ++
        unknown_keys(descriptor, @allowed_root_keys, "integrations")

    {documentation, errors} =
      validate_documentation(Map.get(descriptor, "documentation"), errors)

    {credential_profiles, errors} =
      validate_profiles(
        Map.get(descriptor, "credential_profiles"),
        schedule_by_id,
        errors
      )

    {inventory_sources, errors} =
      validate_inventory_sources(Map.get(descriptor, "inventory_sources"), errors)

    errors =
      errors
      |> duplicate_errors(credential_profiles, "provider", "integrations.credential_profiles")
      |> duplicate_errors(inventory_sources, "source", "integrations.inventory_sources")

    case errors do
      [] ->
        {:ok,
         %{
           "documentation" => documentation,
           "credential_profiles" => credential_profiles,
           "inventory_sources" => inventory_sources
         }}

      _ ->
        {:error, Enum.reverse(errors)}
    end
  end

  def validate(_value, _producer_schedules), do: {:error, ["integrations must be a map"]}

  @spec empty() :: descriptor()
  def empty do
    %{
      "documentation" => %{},
      "credential_profiles" => [],
      "inventory_sources" => []
    }
  end

  defp validate_documentation(nil, errors), do: {%{}, errors}

  defp validate_documentation(value, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)

    errors =
      unknown_keys(value, @allowed_documentation_keys, "integrations.documentation") ++ errors

    {title, errors} = optional_label(value, "title", "integrations.documentation.title", errors)
    {path, errors} = required_string(value, "path", "integrations.documentation.path", errors)
    {url, errors} = optional_documentation_url(value, errors)

    errors =
      if is_binary(path) and safe_documentation_path?(path) do
        errors
      else
        ["integrations.documentation.path must reference a relative docs/*.md file" | errors]
      end

    {%{}
     |> maybe_put("title", title)
     |> maybe_put("path", path)
     |> maybe_put("url", url), errors}
  end

  defp validate_documentation(_value, errors),
    do: {%{}, ["integrations.documentation must be a map" | errors]}

  defp validate_profiles(nil, _schedule_by_id, errors), do: {[], errors}

  defp validate_profiles(values, schedule_by_id, errors)
       when is_list(values) and length(values) <= @max_profiles do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {profiles, acc_errors} ->
      case validate_profile(value, index, schedule_by_id) do
        {:ok, profile} -> {[profile | profiles], acc_errors}
        {:error, profile_errors} -> {profiles, profile_errors ++ acc_errors}
      end
    end)
    |> then(fn {profiles, acc_errors} -> {Enum.reverse(profiles), acc_errors} end)
  end

  defp validate_profiles(_values, _schedule_by_id, errors) do
    {[],
     [
       "integrations.credential_profiles must be a list with at most #{@max_profiles} entries"
       | errors
     ]}
  end

  defp validate_profile(value, index, schedule_by_id) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "integrations.credential_profiles[#{index}]"

    errors =
      forbidden_authority_errors(value, path) ++ unknown_keys(value, @allowed_profile_keys, path)

    {provider, errors} = required_id(value, "provider", "#{path}.provider", errors)
    {label, errors} = required_label(value, "label", "#{path}.label", errors)

    {description, errors} =
      optional_description(value, "description", "#{path}.description", errors)

    {auth_methods, errors} =
      validate_auth_methods(Map.get(value, "auth_methods"), "#{path}.auth_methods", errors)

    {purposes, errors} = id_list(Map.get(value, "purposes"), "#{path}.purposes", errors)

    {scope_types, errors} =
      enum_list(
        Map.get(value, "scope_types"),
        @allowed_scope_types,
        "#{path}.scope_types",
        errors
      )

    {rule_defaults, errors} =
      validate_rule_defaults(
        Map.get(value, "rule_defaults"),
        path,
        auth_methods,
        purposes,
        scope_types,
        errors
      )

    {rule_controls, errors} =
      validate_rule_controls(Map.get(value, "rule_controls"), path, errors)

    {default?, errors} = optional_boolean(value, "default", false, "#{path}.default", errors)

    {supports_rules?, errors} =
      optional_boolean(value, "supports_rules", true, "#{path}.supports_rules", errors)

    {provisioning, errors} =
      validate_provisioning(
        Map.get(value, "provisioning"),
        path,
        schedule_by_id,
        auth_methods,
        purposes,
        supports_rules?,
        errors
      )

    errors = validate_single_cardinality_scope_types(provisioning, scope_types, path, errors)

    case errors do
      [] ->
        {:ok,
         maybe_put(
           %{
             "provider" => provider,
             "label" => label,
             "auth_methods" => auth_methods,
             "purposes" => purposes,
             "scope_types" => scope_types,
             "provisioning" => provisioning,
             "rule_defaults" => rule_defaults,
             "rule_controls" => rule_controls,
             "default" => default?,
             "supports_rules" => supports_rules?
           },
           "description",
           description
         )}

      _ ->
        {:error, errors}
    end
  end

  defp validate_profile(_value, index, _schedule_by_id),
    do: {:error, ["integrations.credential_profiles[#{index}] must be a map"]}

  # A rule carries one scope, shared by every purpose it feeds, and the
  # materializer reconciles each agent that scope admits separately. A
  # `single` consumer does the rule's whole job in one run, so a gateway- or
  # partition-scoped rule delivers that whole job once per agent under the
  # scope: for NetBox, one complete /api/dcim/devices/ walk and one complete
  # DeviceDiscovery snapshot per agent, all claiming the same source_instance.
  # Only an agent scope names a single runner, so a profile with such a
  # consumer may not offer the operator anything else -- the rule form renders
  # its scope options from this list and validates the submitted value against
  # it, so a widened list is a widened form.
  defp validate_single_cardinality_scope_types(provisioning, scope_types, path, errors) do
    consumers = provisioning |> Map.get("consumers") |> List.wrap()

    single? =
      Enum.any?(consumers, &(is_map(&1) and Map.get(&1, "target_cardinality") == "single"))

    if single? and scope_types != ["agent"] do
      [
        ~s(#{path}.scope_types must be ["agent"] when a consumer declares target_cardinality: single)
        | errors
      ]
    else
      errors
    end
  end

  defp validate_auth_methods(values, path, errors) when is_list(values) and values != [] do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {methods, acc_errors} ->
      item_path = "#{path}[#{index}]"

      if is_map(value) do
        value = MapUtils.stringify_keys(value)
        item_errors = unknown_keys(value, @allowed_auth_method_keys, item_path)

        {id, item_errors} = required_id(value, "id", "#{item_path}.id", item_errors)

        {label, item_errors} =
          required_label(value, "label", "#{item_path}.label", item_errors)

        {description, item_errors} =
          optional_description(value, "description", "#{item_path}.description", item_errors)

        {kind, item_errors} =
          enum(
            value,
            "credential_kind",
            @allowed_credential_kinds,
            "#{item_path}.credential_kind",
            item_errors
          )

        {fields, item_errors} =
          validate_credential_fields(Map.get(value, "fields"), item_path, item_errors)

        {payload, item_errors} =
          validate_credential_payload(Map.get(value, "payload"), fields, item_path, item_errors)

        {tls_policies, item_errors} =
          optional_enum_list(
            Map.get(value, "tls_policies"),
            @allowed_tls_policies,
            "#{item_path}.tls_policies",
            item_errors
          )

        {ssh_host_key_policies, item_errors} =
          optional_enum_list(
            Map.get(value, "ssh_host_key_policies"),
            @allowed_ssh_host_key_policies,
            "#{item_path}.ssh_host_key_policies",
            item_errors
          )

        if item_errors == [] do
          method =
            maybe_put(
              %{
                "id" => id,
                "label" => label,
                "credential_kind" => kind,
                "fields" => fields,
                "payload" => payload,
                "tls_policies" => tls_policies,
                "ssh_host_key_policies" => ssh_host_key_policies
              },
              "description",
              description
            )

          {[method | methods], acc_errors}
        else
          {methods, item_errors ++ acc_errors}
        end
      else
        {methods, ["#{item_path} must be a map" | acc_errors]}
      end
    end)
    |> then(fn {methods, acc_errors} ->
      methods = Enum.reverse(methods)
      {methods, duplicate_errors(acc_errors, methods, "id", path)}
    end)
  end

  defp validate_auth_methods(_values, path, errors),
    do: {[], ["#{path} must be a non-empty list" | errors]}

  defp validate_credential_fields(values, method_path, errors)
       when is_list(values) and values != [] and length(values) <= @max_credential_fields do
    path = "#{method_path}.fields"

    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {fields, acc_errors} ->
      item_path = "#{path}[#{index}]"

      if is_map(value) do
        value = MapUtils.stringify_keys(value)
        item_errors = unknown_keys(value, @allowed_credential_field_keys, item_path)
        {id, item_errors} = required_id(value, "id", "#{item_path}.id", item_errors)
        {label, item_errors} = required_label(value, "label", "#{item_path}.label", item_errors)

        {description, item_errors} =
          optional_description(value, "description", "#{item_path}.description", item_errors)

        {placeholder, item_errors} =
          optional_label(value, "placeholder", "#{item_path}.placeholder", item_errors)

        {default, item_errors} =
          optional_bounded_string(
            value,
            "default",
            @max_credential_field_bytes,
            "#{item_path}.default",
            item_errors
          )

        {control, item_errors} =
          enum(
            value,
            "control",
            @allowed_credential_controls,
            "#{item_path}.control",
            item_errors
          )

        {required, item_errors} =
          optional_boolean(value, "required", false, "#{item_path}.required", item_errors)

        {secret, item_errors} =
          optional_boolean(
            value,
            "secret",
            control == "password",
            "#{item_path}.secret",
            item_errors
          )

        {public, item_errors} =
          optional_boolean(value, "public", false, "#{item_path}.public", item_errors)

        {min_length, item_errors} =
          optional_bounded_integer(
            value,
            "min_length",
            0,
            @max_credential_field_bytes,
            "#{item_path}.min_length",
            item_errors
          )

        {max_length, item_errors} =
          optional_bounded_integer(
            value,
            "max_length",
            1,
            @max_credential_field_bytes,
            "#{item_path}.max_length",
            item_errors
          )

        item_errors =
          cond do
            secret and public ->
              ["#{item_path} cannot be both secret and public" | item_errors]

            secret and not is_nil(default) ->
              ["#{item_path}.default is not allowed for secret fields" | item_errors]

            is_integer(min_length) and is_integer(max_length) and min_length > max_length ->
              ["#{item_path}.min_length must not exceed max_length" | item_errors]

            true ->
              item_errors
          end

        if item_errors == [] do
          field =
            %{
              "id" => id,
              "label" => label,
              "control" => control,
              "required" => required,
              "secret" => secret,
              "public" => public
            }
            |> maybe_put("description", description)
            |> maybe_put("placeholder", placeholder)
            |> maybe_put("default", default)
            |> maybe_put("min_length", min_length)
            |> maybe_put("max_length", max_length)

          {[field | fields], acc_errors}
        else
          {fields, item_errors ++ acc_errors}
        end
      else
        {fields, ["#{item_path} must be a map" | acc_errors]}
      end
    end)
    |> then(fn {fields, acc_errors} ->
      fields = Enum.reverse(fields)
      acc_errors = duplicate_errors(acc_errors, fields, "id", path)

      acc_errors =
        if Enum.any?(fields, &Map.get(&1, "secret", false)) do
          acc_errors
        else
          ["#{path} must declare at least one secret field" | acc_errors]
        end

      {fields, acc_errors}
    end)
  end

  defp validate_credential_fields(_values, method_path, errors) do
    {[],
     [
       "#{method_path}.fields must be a non-empty list with at most #{@max_credential_fields} entries"
       | errors
     ]}
  end

  defp validate_credential_payload(nil, _fields, _method_path, errors),
    do: {%{"format" => "json"}, errors}

  defp validate_credential_payload(value, fields, method_path, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{method_path}.payload"
    errors = unknown_keys(value, @allowed_payload_keys, path) ++ errors
    {format, errors} = enum(value, "format", @allowed_payload_formats, "#{path}.format", errors)
    field_ids = Enum.map(fields, & &1["id"])
    secret_field_ids = fields |> Enum.filter(& &1["secret"]) |> Enum.map(& &1["id"])
    public_field_ids = fields |> Enum.filter(& &1["public"]) |> Enum.map(& &1["id"])

    {field, errors} =
      optional_declared_field(value, "field", field_ids, "#{path}.field", errors)

    {username_field, errors} =
      optional_declared_field(
        value,
        "username_field",
        public_field_ids,
        "#{path}.username_field",
        errors
      )

    {template, errors} =
      optional_bounded_string(
        value,
        "template",
        @max_credential_field_bytes,
        "#{path}.template",
        errors
      )

    placeholders = payload_template_placeholders(template)

    errors =
      cond do
        format == "scalar" and field not in secret_field_ids ->
          ["#{path}.field must reference a declared secret field for scalar encoding" | errors]

        format == "scalar" and not is_nil(template) ->
          ["#{path}.template is not allowed for scalar encoding" | errors]

        format == "json" and (not is_nil(field) or not is_nil(template)) ->
          ["#{path}.field and template are not allowed for JSON encoding" | errors]

        format == "template" and (is_nil(template) or placeholders == []) ->
          ["#{path}.template must contain at least one declared field placeholder" | errors]

        format == "template" and Enum.any?(placeholders, &(&1 not in field_ids)) ->
          ["#{path}.template references an undeclared credential field" | errors]

        format == "template" and Enum.all?(placeholders, &(&1 not in secret_field_ids)) ->
          ["#{path}.template must include at least one secret field" | errors]

        true ->
          errors
      end

    payload =
      %{"format" => format}
      |> maybe_put("field", field)
      |> maybe_put("template", template)
      |> maybe_put("username_field", username_field)

    {payload, errors}
  end

  defp validate_credential_payload(_value, _fields, method_path, errors),
    do: {%{}, ["#{method_path}.payload must be a map" | errors]}

  defp payload_template_placeholders(template) when is_binary(template) do
    ~r/\{\{([a-z0-9_.-]+)\}\}/
    |> Regex.scan(template, capture: :all_but_first)
    |> Enum.map(&List.first/1)
    |> Enum.uniq()
  end

  defp payload_template_placeholders(_template), do: []

  defp validate_rule_defaults(nil, _profile_path, _auth_methods, _purposes, _scope_types, errors),
    do: {%{}, errors}

  defp validate_rule_defaults(value, profile_path, auth_methods, purposes, scope_types, errors)
       when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{profile_path}.rule_defaults"
    errors = unknown_keys(value, @allowed_rule_default_keys, path) ++ errors
    auth_ids = Enum.map(auth_methods, & &1["id"])

    errors =
      errors
      |> validate_optional_member(value, "auth_method", auth_ids, path)
      |> validate_optional_member(value, "scope_type", scope_types, path)
      |> validate_optional_member(value, "tls_policy", @allowed_tls_policies, path)
      |> validate_optional_member(
        value,
        "ssh_host_key_policy",
        @allowed_ssh_host_key_policies,
        path
      )
      |> validate_optional_id_subset(value, "purposes", purposes, path)
      |> validate_optional_string_value(value, "target_query", @max_description_bytes, path)
      |> validate_optional_string_value(value, "allowed_ports", @max_label_bytes, path)
      |> validate_optional_string_value(value, "credential_use_roles", @max_label_bytes, path)
      |> validate_optional_string_value(value, "controller_host", @max_label_bytes, path)
      |> validate_optional_boolean_value(value, "auto_discovery_enabled", path)

    {value, errors}
  end

  defp validate_rule_defaults(
         _value,
         profile_path,
         _auth_methods,
         _purposes,
         _scope_types,
         errors
       ),
       do: {%{}, ["#{profile_path}.rule_defaults must be a map" | errors]}

  defp validate_rule_controls(nil, _profile_path, errors), do: {%{}, errors}

  defp validate_rule_controls(value, profile_path, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{profile_path}.rule_controls"
    errors = unknown_keys(value, @allowed_rule_control_keys, path) ++ errors

    errors =
      Enum.reduce(Map.keys(value), errors, fn key, acc ->
        validate_optional_boolean_value(acc, value, key, path)
      end)

    {value, errors}
  end

  defp validate_rule_controls(_value, profile_path, errors),
    do: {%{}, ["#{profile_path}.rule_controls must be a map" | errors]}

  defp validate_provisioning(
         value,
         profile_path,
         schedule_by_id,
         auth_methods,
         purposes,
         supports_rules?,
         errors
       )
       when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{profile_path}.provisioning"
    errors = unknown_keys(value, @allowed_provisioning_keys, path) ++ errors
    {mode, errors} = enum(value, "mode", @allowed_provisioning_modes, "#{path}.mode", errors)

    case mode do
      "credential_only" ->
        errors =
          if supports_rules?,
            do: [
              "#{profile_path}.supports_rules must be false for credential-only profiles" | errors
            ],
            else: errors

        {%{"mode" => mode}, reject_provisioning_keys(value, ~w(mode), path, errors)}

      "producer_schedule" ->
        validate_producer_schedule_provisioning(value, path, schedule_by_id, mode, errors)

      "target_policy" ->
        validate_target_policy_provisioning(
          value,
          path,
          Enum.map(auth_methods, & &1["id"]),
          purposes,
          mode,
          errors
        )

      _ ->
        {%{}, errors}
    end
  end

  defp validate_provisioning(
         _value,
         profile_path,
         _schedule_by_id,
         _auth_methods,
         _purposes,
         _supports_rules?,
         errors
       ),
       do: {%{}, ["#{profile_path}.provisioning must be a map" | errors]}

  defp validate_producer_schedule_provisioning(value, path, schedule_by_id, mode, errors) do
    {schedule_id, errors} = required_id(value, "schedule_id", "#{path}.schedule_id", errors)

    {credential_requirement, errors} =
      required_id(
        value,
        "credential_requirement",
        "#{path}.credential_requirement",
        errors
      )

    schedule = Map.get(schedule_by_id, schedule_id)

    errors =
      cond do
        is_nil(schedule_id) ->
          errors

        is_nil(schedule) ->
          ["#{path}.schedule_id must reference a declared producer schedule" | errors]

        not Map.has_key?(
          Map.get(schedule, "credential_requirements", %{}),
          credential_requirement
        ) ->
          [
            "#{path}.credential_requirement must reference a requirement on the producer schedule"
            | errors
          ]

        true ->
          errors
      end

    errors =
      reject_provisioning_keys(value, ~w(mode schedule_id credential_requirement), path, errors)

    {%{
       "mode" => mode,
       "schedule_id" => schedule_id,
       "credential_requirement" => credential_requirement
     }, errors}
  end

  defp validate_target_policy_provisioning(value, path, auth_methods, purposes, mode, errors) do
    {consumers, errors} =
      validate_consumers(Map.get(value, "consumers"), path, auth_methods, purposes, errors)

    errors = reject_provisioning_keys(value, ~w(mode consumers), path, errors)
    {%{"mode" => mode, "consumers" => consumers}, errors}
  end

  defp reject_provisioning_keys(value, allowed, path, errors) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.reduce(errors, fn key, acc -> ["#{path}.#{key} is not valid for this mode" | acc] end)
  end

  defp validate_consumers(values, provisioning_path, auth_methods, purposes, errors)
       when is_list(values) and values != [] and length(values) <= @max_consumers do
    path = "#{provisioning_path}.consumers"

    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {consumers, acc_errors} ->
      case validate_consumer(value, "#{path}[#{index}]", auth_methods, purposes) do
        {:ok, consumer} -> {[consumer | consumers], acc_errors}
        {:error, consumer_errors} -> {consumers, consumer_errors ++ acc_errors}
      end
    end)
    |> then(fn {consumers, acc_errors} ->
      consumers = Enum.reverse(consumers)
      pairs = Enum.flat_map(consumers, &consumer_auth_pairs/1)
      acc_errors = duplicate_pair_errors(acc_errors, pairs, path)

      acc_errors =
        Enum.reduce(purposes, acc_errors, fn purpose, purpose_errors ->
          if Enum.any?(consumers, &(&1["purpose"] == purpose)),
            do: purpose_errors,
            else: ["#{path} must declare a consumer for purpose #{purpose}" | purpose_errors]
        end)

      {consumers, acc_errors}
    end)
  end

  defp validate_consumers(_values, provisioning_path, _auth_methods, _purposes, errors) do
    {[],
     [
       "#{provisioning_path}.consumers must be a non-empty list with at most #{@max_consumers} entries"
       | errors
     ]}
  end

  defp validate_consumer(value, path, profile_auth_methods, profile_purposes)
       when is_map(value) do
    value = MapUtils.stringify_keys(value)
    errors = unknown_keys(value, @allowed_consumer_keys, path)

    {purpose, errors} =
      required_member(value, "purpose", profile_purposes, "#{path}.purpose", errors)

    {plugin_id, errors} = required_id(value, "plugin_id", "#{path}.plugin_id", errors)

    {auth_methods, errors} =
      id_subset(
        Map.get(value, "auth_methods"),
        profile_auth_methods,
        "#{path}.auth_methods",
        errors
      )

    {constraints, errors} =
      validate_consumer_constraints(Map.get(value, "constraints"), path, errors)

    {failure_mode, errors} =
      optional_enum_value(
        value,
        "failure_mode",
        @allowed_failure_modes,
        "error",
        "#{path}.failure_mode",
        errors
      )

    {target_cardinality, errors} =
      optional_enum_value(
        value,
        "target_cardinality",
        @allowed_target_cardinalities,
        "per_target",
        "#{path}.target_cardinality",
        errors
      )

    {grant, errors} = validate_grant(Map.get(value, "grant"), path, errors)

    {params, errors} =
      case CredentialParameterTemplate.validate(Map.get(value, "params"), "#{path}.params") do
        {:ok, %{} = params} -> {params, errors}
        {:ok, _other} -> {%{}, ["#{path}.params must be a map" | errors]}
        {:error, template_errors} -> {%{}, Enum.reverse(template_errors, errors)}
      end

    case errors do
      [] ->
        {:ok,
         %{
           "purpose" => purpose,
           "plugin_id" => plugin_id,
           "auth_methods" => auth_methods,
           "constraints" => constraints,
           "failure_mode" => failure_mode,
           "target_cardinality" => target_cardinality,
           "grant" => grant,
           "params" => params
         }}

      _ ->
        {:error, errors}
    end
  end

  defp validate_consumer(_value, path, _profile_auth_methods, _profile_purposes),
    do: {:error, ["#{path} must be a map"]}

  defp validate_consumer_constraints(nil, _consumer_path, errors), do: {%{}, errors}

  defp validate_consumer_constraints(value, consumer_path, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{consumer_path}.constraints"
    errors = unknown_keys(value, @allowed_constraint_keys, path) ++ errors

    {tls_policies, errors} =
      optional_enum_list(
        Map.get(value, "tls_policies"),
        @allowed_tls_policies,
        "#{path}.tls_policies",
        errors
      )

    {ssh_policies, errors} =
      optional_enum_list(
        Map.get(value, "ssh_host_key_policies"),
        @allowed_ssh_host_key_policies,
        "#{path}.ssh_host_key_policies",
        errors
      )

    {%{"tls_policies" => tls_policies, "ssh_host_key_policies" => ssh_policies}, errors}
  end

  defp validate_consumer_constraints(_value, consumer_path, errors),
    do: {%{}, ["#{consumer_path}.constraints must be a map" | errors]}

  defp validate_grant(value, consumer_path, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{consumer_path}.grant"
    errors = unknown_keys(value, @allowed_grant_keys, path) ++ errors
    {grant_type, errors} = required_id(value, "grant_type", "#{path}.grant_type", errors)

    {resolution_location, errors} =
      required_member(
        value,
        "resolution_location",
        @allowed_resolution_locations,
        "#{path}.resolution_location",
        errors
      )

    {inject, errors} = validate_grant_inject(Map.get(value, "inject"), path, errors)
    {allow, errors} = validate_grant_allow(Map.get(value, "allow"), path, errors)

    {ttl_seconds, errors} =
      optional_bounded_integer(
        value,
        "ttl_seconds",
        1,
        86_400,
        "#{path}.ttl_seconds",
        errors
      )

    ttl_seconds = ttl_seconds || 300

    {payload, errors} =
      case Map.get(value, "payload") do
        nil ->
          {%{}, errors}

        payload ->
          case CredentialParameterTemplate.validate(payload, "#{path}.payload") do
            {:ok, %{} = normalized} ->
              errors =
                if CredentialParameterTemplate.references_source?(normalized, "grant") do
                  ["#{path}.payload cannot reference its own grant" | errors]
                else
                  errors
                end

              {normalized, errors}

            {:ok, _other} ->
              {%{}, ["#{path}.payload must be a map" | errors]}

            {:error, payload_errors} ->
              {%{}, Enum.reverse(payload_errors, errors)}
          end
      end

    {%{
       "grant_type" => grant_type,
       "resolution_location" => resolution_location,
       "inject" => inject,
       "allow" => allow,
       "ttl_seconds" => ttl_seconds,
       "payload" => payload
     }, errors}
  end

  defp validate_grant(_value, consumer_path, errors),
    do: {%{}, ["#{consumer_path}.grant must be a map" | errors]}

  defp validate_grant_inject(nil, _grant_path, errors), do: {%{}, errors}

  defp validate_grant_inject(value, grant_path, errors)
       when is_map(value) and map_size(value) <= @max_grant_entries do
    value = MapUtils.stringify_keys(value)
    path = "#{grant_path}.inject"
    type = Map.get(value, "type")

    errors =
      if type in @allowed_injection_types,
        do: errors,
        else: ["#{path}.type contains an unsupported value" | errors]

    errors =
      Enum.reduce(value, errors, fn {key, item}, acc ->
        cond do
          not valid_injection_key?(key) -> ["#{path}.#{key} is not allowed" | acc]
          not is_binary(item) -> ["#{path}.#{key} must be a string" | acc]
          byte_size(item) > @max_path_bytes -> ["#{path}.#{key} is too long" | acc]
          true -> acc
        end
      end)

    {value, errors}
  end

  defp validate_grant_inject(_value, grant_path, errors),
    do: {%{}, ["#{grant_path}.inject must be a bounded map" | errors]}

  defp validate_grant_allow(nil, _grant_path, errors), do: {%{}, errors}

  defp validate_grant_allow(value, grant_path, errors) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "#{grant_path}.allow"
    errors = unknown_keys(value, @allowed_grant_allow_keys, path) ++ errors

    {methods, errors} =
      optional_http_methods(Map.get(value, "methods"), "#{path}.methods", errors)

    {paths, errors} =
      optional_bounded_string_list(Map.get(value, "paths"), "#{path}.paths", errors)

    {hosts, errors} =
      optional_bounded_string_list(Map.get(value, "hosts"), "#{path}.hosts", errors)

    {ports, errors} = optional_ports(Map.get(value, "ports"), "#{path}.ports", errors)
    {%{"methods" => methods, "paths" => paths, "hosts" => hosts, "ports" => ports}, errors}
  end

  defp validate_grant_allow(_value, grant_path, errors),
    do: {%{}, ["#{grant_path}.allow must be a map" | errors]}

  defp valid_injection_key?(key) do
    key in ~w(
      type name scheme prefix separator value_template allow_insecure_tls method host path
      token_method token_host token_port token_path response_field
    ) or Regex.match?(~r/^(field|fixed)_[a-z0-9_.-]+$/, key)
  end

  defp consumer_auth_pairs(consumer) do
    Enum.map(consumer["auth_methods"], &{consumer["purpose"], &1})
  end

  defp duplicate_pair_errors(errors, pairs, path) do
    pairs
    |> Enum.frequencies()
    |> Enum.reduce(errors, fn
      {{purpose, auth_method}, count}, acc when count > 1 ->
        ["#{path} contains duplicate #{purpose}/#{auth_method} consumers" | acc]

      _, acc ->
        acc
    end)
  end

  defp validate_inventory_sources(nil, errors), do: {[], errors}

  defp validate_inventory_sources(values, errors)
       when is_list(values) and length(values) <= @max_sources do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {sources, acc_errors} ->
      case validate_inventory_source(value, index) do
        {:ok, source} -> {[source | sources], acc_errors}
        {:error, source_errors} -> {sources, source_errors ++ acc_errors}
      end
    end)
    |> then(fn {sources, acc_errors} -> {Enum.reverse(sources), acc_errors} end)
  end

  defp validate_inventory_sources(_values, errors) do
    {[],
     [
       "integrations.inventory_sources must be a list with at most #{@max_sources} entries"
       | errors
     ]}
  end

  defp validate_inventory_source(value, index) when is_map(value) do
    value = MapUtils.stringify_keys(value)
    path = "integrations.inventory_sources[#{index}]"

    errors =
      forbidden_authority_errors(value, path) ++
        unknown_keys(value, @allowed_inventory_source_keys, path)

    {source, errors} = required_id(value, "source", "#{path}.source", errors)
    {label, errors} = required_label(value, "label", "#{path}.label", errors)

    {description, errors} =
      optional_description(value, "description", "#{path}.description", errors)

    {metadata_fields, errors} =
      validate_metadata_fields(Map.get(value, "metadata_fields"), path, errors)

    {emitted_facts, errors} =
      validate_emitted_facts(Map.get(value, "emitted_facts"), "#{path}.emitted_facts", errors)

    case errors do
      [] ->
        {:ok,
         %{"source" => source, "label" => label, "metadata_fields" => metadata_fields}
         |> maybe_put("description", description)
         |> maybe_put("emitted_facts", emitted_facts)}

      _ ->
        {:error, errors}
    end
  end

  defp validate_inventory_source(_value, index),
    do: {:error, ["integrations.inventory_sources[#{index}] must be a map"]}

  defp validate_metadata_fields(nil, _source_path, errors), do: {[], errors}

  defp validate_metadata_fields(values, source_path, errors)
       when is_list(values) and length(values) <= @max_metadata_fields do
    path = "#{source_path}.metadata_fields"

    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], errors}, fn {value, index}, {fields, acc_errors} ->
      item_path = "#{path}[#{index}]"

      if is_map(value) do
        value = MapUtils.stringify_keys(value)
        item_errors = unknown_keys(value, @allowed_metadata_field_keys, item_path)
        {key, item_errors} = required_metadata_key(value, item_path, item_errors)
        {label, item_errors} = required_label(value, "label", "#{item_path}.label", item_errors)

        {description, item_errors} =
          optional_description(value, "description", "#{item_path}.description", item_errors)

        {format, item_errors} =
          optional_enum(
            value,
            "format",
            @allowed_field_formats,
            "#{item_path}.format",
            item_errors
          )

        if item_errors == [] do
          field =
            maybe_put(
              %{"key" => key, "label" => label, "format" => format || "text"},
              "description",
              description
            )

          {[field | fields], acc_errors}
        else
          {fields, item_errors ++ acc_errors}
        end
      else
        {fields, ["#{item_path} must be a map" | acc_errors]}
      end
    end)
    |> then(fn {fields, acc_errors} ->
      fields = Enum.reverse(fields)
      {fields, duplicate_errors(acc_errors, fields, "key", path)}
    end)
  end

  defp validate_metadata_fields(_values, source_path, errors) do
    {[],
     [
       "#{source_path}.metadata_fields must be a list with at most #{@max_metadata_fields} entries"
       | errors
     ]}
  end

  defp required_metadata_key(value, path, errors) do
    case normalized_string(Map.get(value, "key")) do
      key when is_binary(key) ->
        if Regex.match?(@metadata_key_regex, key) do
          {key, errors}
        else
          {nil, ["#{path}.key is invalid" | errors]}
        end

      _ ->
        {nil, ["#{path}.key must be a non-empty string" | errors]}
    end
  end

  defp enum_list(values, allowed, path, errors) when is_list(values) and values != [] do
    normalized = Enum.map(values, &normalized_string/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {[], ["#{path} must contain non-empty strings" | errors]}

      Enum.any?(normalized, &(&1 not in allowed)) ->
        {[], ["#{path} contains an unsupported value" | errors]}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {[], ["#{path} must not contain duplicates" | errors]}

      true ->
        {normalized, errors}
    end
  end

  defp enum_list(_values, _allowed, path, errors),
    do: {[], ["#{path} must be a non-empty list" | errors]}

  defp optional_enum_list(nil, _allowed, _path, errors), do: {[], errors}

  defp optional_enum_list(values, allowed, path, errors),
    do: enum_list(values, allowed, path, errors)

  defp id_list(values, path, errors) when is_list(values) and values != [] do
    normalized = Enum.map(values, &normalized_string/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {[], ["#{path} must contain non-empty identifiers" | errors]}

      Enum.any?(normalized, &(not Regex.match?(@id_regex, &1))) ->
        {[], ["#{path} contains an invalid identifier" | errors]}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {[], ["#{path} must not contain duplicates" | errors]}

      true ->
        {normalized, errors}
    end
  end

  defp id_list(_values, path, errors), do: {[], ["#{path} must be a non-empty list" | errors]}

  defp id_subset(values, allowed, path, errors) do
    {ids, next_errors} = id_list(values, path, errors)

    if Enum.all?(ids, &(&1 in allowed)),
      do: {ids, next_errors},
      else: {ids, ["#{path} contains an undeclared identifier" | next_errors]}
  end

  defp optional_declared_field(value, key, allowed, path, errors) do
    case normalized_string(Map.get(value, key)) do
      nil ->
        {nil, errors}

      field ->
        if field in allowed,
          do: {field, errors},
          else: {nil, ["#{path} must reference a declared field" | errors]}
    end
  end

  defp required_member(value, key, allowed, path, errors) do
    member = normalized_string(Map.get(value, key))

    if member in allowed,
      do: {member, errors},
      else: {nil, ["#{path} contains an unsupported value" | errors]}
  end

  defp optional_enum_value(value, key, allowed, default, path, errors) do
    case Map.get(value, key) do
      nil -> {default, errors}
      _ -> required_member(value, key, allowed, path, errors)
    end
  end

  defp validate_optional_member(errors, value, key, allowed, path) do
    case Map.get(value, key) do
      nil ->
        errors

      member ->
        if member in allowed,
          do: errors,
          else: ["#{path}.#{key} contains an unsupported value" | errors]
    end
  end

  defp validate_optional_id_subset(errors, value, key, allowed, path) do
    case Map.get(value, key) do
      nil ->
        errors

      values when is_list(values) and values != [] ->
        cond do
          Enum.any?(values, &(not is_binary(&1) or &1 not in allowed)) ->
            ["#{path}.#{key} contains an undeclared identifier" | errors]

          length(Enum.uniq(values)) != length(values) ->
            ["#{path}.#{key} must not contain duplicates" | errors]

          true ->
            errors
        end

      _ ->
        ["#{path}.#{key} must be a non-empty list" | errors]
    end
  end

  defp validate_optional_string_value(errors, value, key, max_bytes, path) do
    case Map.get(value, key) do
      nil ->
        errors

      string when is_binary(string) and byte_size(string) <= max_bytes ->
        errors

      _ ->
        ["#{path}.#{key} must be a string up to #{max_bytes} bytes" | errors]
    end
  end

  defp validate_optional_boolean_value(errors, value, key, path) do
    case Map.get(value, key) do
      nil -> errors
      boolean when is_boolean(boolean) -> errors
      _ -> ["#{path}.#{key} must be a boolean" | errors]
    end
  end

  defp optional_http_methods(nil, _path, errors), do: {[], errors}

  defp optional_http_methods(values, path, errors)
       when is_list(values) and length(values) <= @max_grant_entries do
    normalized =
      Enum.map(values, fn
        value when is_binary(value) -> value |> String.trim() |> String.upcase()
        _value -> nil
      end)

    cond do
      Enum.any?(normalized, &(is_nil(&1) or &1 not in @allowed_http_methods)) ->
        {[], ["#{path} contains an unsupported HTTP method" | errors]}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {[], ["#{path} must not contain duplicates" | errors]}

      true ->
        {normalized, errors}
    end
  end

  defp optional_http_methods(_values, path, errors),
    do: {[], ["#{path} must be a bounded list" | errors]}

  defp optional_bounded_string_list(nil, _path, errors), do: {[], errors}

  defp optional_bounded_string_list(values, path, errors)
       when is_list(values) and length(values) <= @max_grant_entries do
    normalized = Enum.map(values, &normalized_string/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {[], ["#{path} must contain non-empty strings" | errors]}

      Enum.any?(normalized, &(byte_size(&1) > @max_path_bytes)) ->
        {[], ["#{path} contains an overlong value" | errors]}

      length(Enum.uniq(normalized)) != length(normalized) ->
        {[], ["#{path} must not contain duplicates" | errors]}

      true ->
        {normalized, errors}
    end
  end

  defp optional_bounded_string_list(_values, path, errors),
    do: {[], ["#{path} must be a bounded list" | errors]}

  defp optional_ports(nil, _path, errors), do: {[], errors}

  defp optional_ports(values, path, errors)
       when is_list(values) and length(values) <= @max_grant_entries do
    if Enum.all?(values, &(is_integer(&1) and &1 > 0 and &1 <= 65_535)) do
      {Enum.uniq(values), errors}
    else
      {[], ["#{path} must contain ports from 1 to 65535" | errors]}
    end
  end

  defp optional_ports(_values, path, errors), do: {[], ["#{path} must be a list" | errors]}

  defp enum(value, key, allowed, path, errors) do
    case normalized_string(Map.get(value, key)) do
      item when is_binary(item) ->
        if item in allowed do
          {item, errors}
        else
          {nil, ["#{path} must be one of: #{Enum.join(allowed, ", ")}" | errors]}
        end

      _ ->
        {nil, ["#{path} must be one of: #{Enum.join(allowed, ", ")}" | errors]}
    end
  end

  defp optional_enum(value, key, allowed, path, errors) do
    case Map.get(value, key) do
      nil -> {nil, errors}
      _ -> enum(value, key, allowed, path, errors)
    end
  end

  defp optional_boolean(value, key, default, path, errors) do
    case Map.get(value, key, default) do
      boolean when is_boolean(boolean) -> {boolean, errors}
      _ -> {default, ["#{path} must be a boolean" | errors]}
    end
  end

  defp optional_bounded_integer(value, key, minimum, maximum, path, errors) do
    case Map.get(value, key) do
      nil ->
        {nil, errors}

      integer when is_integer(integer) and integer >= minimum and integer <= maximum ->
        {integer, errors}

      _ ->
        {nil, ["#{path} must be an integer between #{minimum} and #{maximum}" | errors]}
    end
  end

  defp optional_bounded_string(value, key, maximum, path, errors) do
    case Map.get(value, key) do
      nil ->
        {nil, errors}

      string when is_binary(string) and byte_size(string) <= maximum ->
        {string, errors}

      _ ->
        {nil, ["#{path} must be a string up to #{maximum} bytes" | errors]}
    end
  end

  defp required_id(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      id when is_binary(id) ->
        if Regex.match?(@id_regex, id) do
          {id, errors}
        else
          {nil, ["#{path} is invalid" | errors]}
        end

      _ ->
        {nil, ["#{path} must be a non-empty string" | errors]}
    end
  end

  defp required_label(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      label when is_binary(label) and byte_size(label) <= @max_label_bytes -> {label, errors}
      _ -> {nil, ["#{path} must be a non-empty string up to #{@max_label_bytes} bytes" | errors]}
    end
  end

  defp optional_label(value, key, path, errors) do
    case Map.get(value, key) do
      nil -> {nil, errors}
      _ -> required_label(value, key, path, errors)
    end
  end

  defp optional_description(value, key, path, errors) do
    case Map.get(value, key) do
      nil ->
        {nil, errors}

      raw ->
        case normalized_string(raw) do
          description
          when is_binary(description) and byte_size(description) <= @max_description_bytes ->
            {description, errors}

          _ ->
            {nil,
             ["#{path} must be a non-empty string up to #{@max_description_bytes} bytes" | errors]}
        end
    end
  end

  defp required_string(value, key, path, errors) do
    case normalized_string(Map.get(value, key)) do
      string when is_binary(string) -> {string, errors}
      _ -> {nil, ["#{path} must be a non-empty string" | errors]}
    end
  end

  defp optional_documentation_url(value, errors) do
    case Map.get(value, "url") do
      nil ->
        {nil, errors}

      raw ->
        case normalized_string(raw) do
          url when is_binary(url) ->
            if safe_documentation_url?(url) do
              {url, errors}
            else
              {nil,
               [
                 "integrations.documentation.url must be an HTTPS URL up to #{@max_documentation_url_bytes} bytes"
                 | errors
               ]}
            end

          _ ->
            {nil,
             [
               "integrations.documentation.url must be an HTTPS URL up to #{@max_documentation_url_bytes} bytes"
               | errors
             ]}
        end
    end
  end

  defp validate_emitted_facts(nil, _path, errors), do: {[], errors}

  defp validate_emitted_facts(values, path, errors) when is_list(values) do
    allowed = MapSet.new(ServiceRadar.Inventory.SourceFacts.keys())

    {facts, errors} =
      Enum.reduce(values, {[], errors}, fn
        value, {acc, acc_errors} when is_binary(value) ->
          if value in allowed do
            {acc ++ [value], acc_errors}
          else
            {acc, ["#{path} contains unknown fact key #{value}" | acc_errors]}
          end

        _value, {acc, acc_errors} ->
          {acc, ["#{path} entries must be strings" | acc_errors]}
      end)

    {Enum.uniq(facts), errors}
  end

  defp validate_emitted_facts(_values, path, errors),
    do: {[], ["#{path} must be a list of fact keys" | errors]}

  defp forbidden_authority_errors(value, path) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.filter(&(&1 in @forbidden_authority_keys))
    |> Enum.map(
      &"#{path}.#{&1} must not declare fact authority or precedence; winners are configured in the platform catalog"
    )
  end

  defp forbidden_authority_errors(_value, _path), do: []

  defp unknown_keys(value, allowed, path) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.map(&"#{path}.#{&1} is not allowed")
  end

  defp duplicate_errors(errors, values, key, path) do
    values
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.reduce(errors, fn
      {value, count}, acc when count > 1 -> ["#{path} contains duplicate #{key} #{value}" | acc]
      _, acc -> acc
    end)
  end

  defp safe_documentation_path?(path) do
    String.starts_with?(path, "docs/") and String.ends_with?(path, ".md") and
      not String.starts_with?(path, "/") and
      not String.contains?(path, ["..", "\\"]) and
      byte_size(path) <= 240
  end

  defp safe_documentation_url?(url) do
    uri = URI.parse(url)

    byte_size(url) <= @max_documentation_url_bytes and uri.scheme == "https" and
      is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo)
  end

  defp normalized_string(nil), do: nil

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalized_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalized_string()

  defp normalized_string(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
