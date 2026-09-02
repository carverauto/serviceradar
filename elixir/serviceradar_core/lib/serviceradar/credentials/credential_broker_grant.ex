defmodule ServiceRadar.Credentials.CredentialBrokerGrant do
  @moduledoc """
  First-class scoped grant for broker-mediated credential resolution.

  Grants are the handoff object between user/runtime intent and trusted
  credential resolution. Payloads may carry grant metadata to agents and task
  runners, but resolved secret values stay behind the broker boundary.
  """

  use Ash.Resource,
    domain: ServiceRadar.Credentials,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Credentials.Changes.WriteBrokerGrantLifecycleEvent
  alias ServiceRadar.Credentials.RequestBodyPolicy
  alias ServiceRadar.Credentials.Validations.GrantPrunableForSecretDeletion
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @schema_v1 "serviceradar.edge_credential_broker_grant.v1"
  @schema_v2 "serviceradar.edge_credential_broker_grant.v2"
  @credential_manage_check {ActorHasPermission, permission: "settings.credentials.manage"}

  @fields [
    :secret_id,
    :secret_ref,
    :credential_rule_id,
    :grant_type,
    :consumer_kind,
    :consumer_id,
    :purpose,
    :target_kind,
    :target_id,
    :agent_id,
    :resolution_location,
    :allowed_schemes,
    :allowed_methods,
    :allowed_paths,
    :allowed_hosts,
    :allowed_ports,
    :request_body_policy,
    :inject,
    :metadata,
    :ttl_seconds,
    :expires_at,
    :issued_by_actor_id
  ]

  postgres do
    table "credential_broker_grants"
    repo ServiceRadar.Repo
    schema "platform"

    references do
      reference :secret, on_delete: :restrict
    end
  end

  state_machine do
    initial_states [:issued]
    default_initial_state :issued
    state_attribute :status

    transitions do
      transition :activate, from: :issued, to: :active
      transition :consume, from: [:issued, :active], to: :consumed
      transition :deny, from: [:issued, :active], to: :denied
      transition :expire, from: [:issued, :active], to: :expired
      transition :revoke, from: [:issued, :active], to: :revoked
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    table_name "credential_broker_grant_versions"
    mixin {ServiceRadar.Credentials.PaperTrailMixin, :cascade_versions, []}
    change_tracking_mode :changes_only
    store_action_name? true
    store_action_inputs? true
    create_version_on_destroy? false
    ignore_attributes [:inserted_at, :updated_at]
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_for_consumer, action: :for_consumer, args: [:consumer_kind, :consumer_id]
    define :issue_grant, action: :issue
    define :activate, action: :activate
    define :consume, action: :consume
    define :deny, action: :deny
    define :expire, action: :expire
    define :revoke, action: :revoke
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :for_consumer do
      argument :consumer_kind, :atom, allow_nil?: false
      argument :consumer_id, :string, allow_nil?: false

      filter expr(consumer_kind == ^arg(:consumer_kind) and consumer_id == ^arg(:consumer_id))

      prepare build(sort: [inserted_at: :desc])
    end

    create :issue do
      accept @fields
      change set_attribute(:issued_at, &__MODULE__.utc_now/0)
      change {WriteBrokerGrantLifecycleEvent, action: :issue}
    end

    update :activate do
      change transition_state(:active)
      change {WriteBrokerGrantLifecycleEvent, action: :activate}
    end

    update :consume do
      change transition_state(:consumed)
      change set_attribute(:consumed_at, &__MODULE__.utc_now/0)
      change {WriteBrokerGrantLifecycleEvent, action: :consume}
    end

    update :deny do
      argument :reason, :string
      change transition_state(:denied)
      change set_attribute(:denied_at, &__MODULE__.utc_now/0)
      change set_attribute(:denial_reason, arg(:reason))
      change {WriteBrokerGrantLifecycleEvent, action: :deny}
    end

    update :expire do
      change transition_state(:expired)
      change {WriteBrokerGrantLifecycleEvent, action: :expire}
    end

    update :revoke do
      argument :reason, :string
      change transition_state(:revoked)
      change set_attribute(:revoked_at, &__MODULE__.utc_now/0)
      change set_attribute(:revocation_reason, arg(:reason))
      change {WriteBrokerGrantLifecycleEvent, action: :revoke}
    end

    destroy :prune_for_secret_deletion do
      public? false
      argument :cutoff, :utc_datetime, allow_nil?: false
      validate GrantPrunableForSecretDeletion
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@credential_manage_check)

    policy action([
             :issue,
             :activate,
             :consume,
             :deny,
             :expire,
             :revoke,
             :prune_for_secret_deletion
           ]) do
      authorize_if actor_attribute_equals(:role, :system)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :secret_ref, :string do
      allow_nil? false
      public? true
    end

    attribute :credential_rule_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :grant_type, :string do
      allow_nil? false
      public? true
    end

    attribute :consumer_kind, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :plugin,
                    :mapper,
                    :discovery,
                    :snmp,
                    :remote_access,
                    :northbound_action,
                    :service_monitoring,
                    :device_task,
                    :ansible,
                    :test
                  ]
    end

    attribute :consumer_id, :string do
      allow_nil? true
      public? true
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
    end

    attribute :target_kind, :string do
      allow_nil? true
      public? true
    end

    attribute :target_id, :string do
      allow_nil? true
      public? true
    end

    attribute :agent_id, :string do
      allow_nil? true
      public? true
    end

    attribute :resolution_location, :atom do
      allow_nil? false
      public? true
      default :control_plane
      constraints one_of: [:control_plane, :agent, :hybrid]
    end

    attribute :allowed_schemes, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :allowed_methods, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :allowed_paths, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :allowed_hosts, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :allowed_ports, {:array, :integer} do
      allow_nil? false
      public? true
      default []
    end

    attribute :request_body_policy, RequestBodyPolicy do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :inject, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :ttl_seconds, :integer do
      allow_nil? false
      public? true
      default 300
      constraints min: 1
    end

    # PaperTrail dumps tracked datetime attributes as :utc_datetime; keep lifecycle
    # timestamps at seconds precision even though the columns support microseconds.
    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :issued_by_actor_id, :string do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :issued
      constraints one_of: [:issued, :active, :consumed, :denied, :expired, :revoked]
    end

    attribute :issued_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :consumed_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :denied_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :denial_reason, :string do
      allow_nil? true
      public? true
    end

    attribute :revoked_at, :utc_datetime do
      allow_nil? true
      public? true
    end

    attribute :revocation_reason, :string do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :secret, ServiceRadar.Credentials.NetworkCredentialSecret do
      allow_nil? true
      public? true
      source_attribute :secret_id
      destination_attribute :id
      define_attribute? false
    end
  end

  def schema, do: @schema_v1
  def body_bound_schema, do: @schema_v2

  @doc "Build issue attrs from the common caller shape and calculate expiry."
  def issue_attrs(attrs, now \\ DateTime.utc_now()) when is_map(attrs) do
    ttl_seconds = int_value(attrs, :ttl_seconds, 300)
    supplied_secret_id = value(attrs, :secret_id)
    secret_ref = value(attrs, :secret_ref) || secret_ref_for(supplied_secret_id)
    secret_id = supplied_secret_id || network_credential_secret_id_from_ref(secret_ref)
    default_expires_at = now |> DateTime.add(ttl_seconds, :second) |> truncate_datetime()

    @fields
    |> Enum.reduce(%{}, fn field, acc ->
      case value(attrs, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
    |> Map.put(:ttl_seconds, ttl_seconds)
    |> Map.put(:secret_ref, secret_ref)
    |> maybe_put_secret_id(secret_id)
    |> Map.update(:expires_at, default_expires_at, &truncate_datetime/1)
  end

  @doc "Build the versioned wire payload used by agents and plugins."
  def to_payload(grant_or_attrs, extras \\ %{}) when is_map(grant_or_attrs) do
    inject = value(grant_or_attrs, :inject) || %{}
    allow = allow_payload(grant_or_attrs)
    request_body_policy = normalize_request_body_policy!(grant_or_attrs)
    expires_at = value(grant_or_attrs, :expires_at) || derived_expires_at(grant_or_attrs)

    %{
      "schema" => schema_for(request_body_policy),
      "grant_id" => stringify(value(grant_or_attrs, :id)),
      "grant_type" => value(grant_or_attrs, :grant_type),
      "credential_rule_id" => stringify(value(grant_or_attrs, :credential_rule_id)),
      "credential_secret_ref" => value(grant_or_attrs, :secret_ref),
      "consumer" => %{
        "kind" => stringify(value(grant_or_attrs, :consumer_kind)),
        "id" => value(grant_or_attrs, :consumer_id),
        "purpose" => value(grant_or_attrs, :purpose)
      },
      "target" => %{
        "kind" => value(grant_or_attrs, :target_kind),
        "id" => value(grant_or_attrs, :target_id),
        "agent_id" => value(grant_or_attrs, :agent_id)
      },
      "resolution_location" => stringify(value(grant_or_attrs, :resolution_location)),
      "inject" => inject,
      "allow" => allow,
      "ttl_seconds" => int_value(grant_or_attrs, :ttl_seconds, 300),
      "expires_at" => iso8601(expires_at)
    }
    |> deep_merge(extras)
    |> compact_map()
  end

  @doc "Validate an already-loaded grant against broker call context."
  def validate_loaded_grant(grant, opts \\ []) when is_map(grant) do
    with :ok <- validate_status(grant),
         :ok <- validate_expiration(grant, Keyword.get(opts, :now, DateTime.utc_now())),
         :ok <- validate_eq(grant, :secret_id, Keyword.get(opts, :secret_id)),
         :ok <-
           validate_eq(
             grant,
             :consumer_kind,
             Keyword.get(opts, :consumer_kind),
             &normalize_atom/1
           ),
         :ok <- validate_eq(grant, :consumer_id, Keyword.get(opts, :consumer_id)),
         :ok <- validate_eq(grant, :purpose, Keyword.get(opts, :purpose)),
         :ok <- validate_eq(grant, :target_kind, Keyword.get(opts, :target_kind)),
         :ok <- validate_eq(grant, :target_id, Keyword.get(opts, :target_id)),
         :ok <- validate_eq(grant, :agent_id, Keyword.get(opts, :agent_id)) do
      validate_eq(
        grant,
        :resolution_location,
        Keyword.get(opts, :resolution_location),
        &normalize_atom/1
      )
    end
  end

  defp validate_status(grant) do
    case normalize_atom(value(grant, :status) || :issued) do
      status when status in [:issued, :active] -> :ok
      status -> {:error, {:grant_not_active, status}}
    end
  end

  defp validate_expiration(grant, now) do
    case value(grant, :expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.after?(expires_at, now), do: :ok, else: {:error, :grant_expired}

      _ ->
        :ok
    end
  end

  defp validate_eq(grant, field, expected, normalizer \\ & &1)
  defp validate_eq(_grant, _field, nil, _normalizer), do: :ok

  defp validate_eq(grant, field, expected, normalizer) do
    actual = value(grant, field)

    if normalizer.(actual) == normalizer.(expected) do
      :ok
    else
      {:error, {:grant_scope_mismatch, field}}
    end
  end

  defp allow_payload(grant_or_attrs) do
    compact_map(%{
      "schemes" => list_value(grant_or_attrs, :allowed_schemes),
      "methods" => list_value(grant_or_attrs, :allowed_methods),
      "paths" => list_value(grant_or_attrs, :allowed_paths),
      "hosts" => list_value(grant_or_attrs, :allowed_hosts),
      "ports" => list_value(grant_or_attrs, :allowed_ports),
      "request_body" => normalize_request_body_policy!(grant_or_attrs)
    })
  end

  defp normalize_request_body_policy!(grant_or_attrs) do
    case RequestBodyPolicy.normalize(value(grant_or_attrs, :request_body_policy) || %{}) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid request body policy: #{inspect(reason)}"
    end
  end

  defp schema_for(policy) when is_map(policy) and map_size(policy) > 0, do: @schema_v2
  defp schema_for(_policy), do: @schema_v1

  defp secret_ref_for(nil), do: nil
  defp secret_ref_for(secret_id), do: SecretRefs.network_credential_ref(to_string(secret_id))

  defp network_credential_secret_id_from_ref(ref) when is_binary(ref) do
    with {:ok, secret_id} <- SecretRefs.network_credential_secret_ref_id(ref),
         {:ok, secret_id} <- Ecto.UUID.cast(secret_id) do
      secret_id
    else
      :error -> nil
      {:error, _reason} -> nil
    end
  end

  defp network_credential_secret_id_from_ref(_ref), do: nil

  defp maybe_put_secret_id(attrs, nil), do: attrs
  defp maybe_put_secret_id(attrs, secret_id), do: Map.put(attrs, :secret_id, secret_id)

  def utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp truncate_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)
  defp truncate_datetime(value), do: value

  defp derived_expires_at(grant_or_attrs) do
    if value(grant_or_attrs, :id) do
      nil
    else
      DateTime.add(utc_now(), int_value(grant_or_attrs, :ttl_seconds, 300), :second)
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp int_value(map, key, default) do
    case value(map, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp list_value(map, key), do: map |> value(key) |> List.wrap() |> Enum.reject(&is_nil/1)

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> value
  end

  defp normalize_atom(value), do: value

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value), do: value

  defp deep_merge(map, extras) when is_map(extras) do
    Map.merge(map, extras, fn
      _key, left, right when is_map(left) and is_map(right) -> deep_merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> empty?(value) end)
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, compact_map(value)}
      pair -> pair
    end)
  end

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(%{} = value), do: map_size(value) == 0
  defp empty?(_), do: false
end
