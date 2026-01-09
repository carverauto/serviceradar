defmodule ServiceRadar.Events.AuditWriter do
  @moduledoc """
  Writes audit events to the OCSF events table within the correct tenant schema.

  Provides a simple, idiomatic interface for recording audit trail events
  across the Elixir stack. Events are written as OCSF Event Log Activity
  (class_uid: 1008) records to the tenant-specific schema.

  ## Usage

      # Synchronous write
      AuditWriter.write(
        tenant_id: tenant_id,
        action: :create,
        resource_type: "integration_source",
        resource_id: source.id,
        resource_name: source.name,
        actor: current_user,
        details: %{endpoint: source.endpoint}
      )

      # Async write (fire and forget)
      AuditWriter.write_async(
        tenant_id: tenant_id,
        action: :update,
        resource_type: "user",
        resource_id: user.id,
        resource_name: user.email,
        actor: admin
      )

  ## Tenant Schema Routing

  Events are written to the correct tenant schema based on the `tenant_id`.
  The schema is resolved via `TenantSchemas.schema_for_id/1` which looks up
  the tenant slug from the TenantRegistry.

  ## Actions

  Supported actions map to OCSF activity IDs:
  - `:create` - Resource created (activity_id: 1)
  - `:read` - Resource accessed (activity_id: 2)
  - `:update` - Resource modified (activity_id: 3)
  - `:delete` - Resource removed (activity_id: 4)

  Custom action atoms are also supported and will use activity_id 3 (Update)
  with the action name preserved in the message.

  ## Required Options

  - `:tenant_id` - UUID of the tenant
  - `:action` - Atom describing the action (:create, :update, :delete, etc.)
  - `:resource_type` - String identifying the resource type (e.g., "user", "integration_source")
  - `:resource_id` - String or UUID of the resource

  ## Optional Options

  - `:resource_name` - Human-readable name for the resource
  - `:actor` - Map with :id, :email keys (user who performed action)
  - `:details` - Map of additional details to include
  - `:message` - Custom message (auto-generated if not provided)
  - `:severity` - :informational (default), :low, :medium, :high, :critical
  """

  require Logger

  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.EventWriter.OCSF
  alias ServiceRadar.Repo

  @type action :: :create | :read | :update | :delete | atom()
  @type severity :: :informational | :low | :medium | :high | :critical

  @type opts :: [
          tenant_id: Ecto.UUID.t(),
          action: action(),
          resource_type: String.t(),
          resource_id: String.t() | Ecto.UUID.t(),
          resource_name: String.t() | nil,
          actor: map() | nil,
          details: map() | nil,
          message: String.t() | nil,
          severity: severity()
        ]

  @doc """
  Write an audit event synchronously.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec write(opts()) :: :ok | {:error, term()}
  def write(opts) do
    with {:ok, tenant_id} <- fetch_required(opts, :tenant_id),
         {:ok, schema} <- resolve_tenant_schema(tenant_id),
         {:ok, event} <- build_event(opts),
         {:ok, encoded_event} <- encode_event(event) do
      case Repo.insert_all("ocsf_events", [encoded_event], prefix: schema, on_conflict: :nothing) do
        {1, _} -> :ok
        {0, _} -> {:error, :insert_failed}
      end
    end
  rescue
    e ->
      Logger.error("Failed to write audit event: #{inspect(e)}")
      {:error, e}
  end

  defp resolve_tenant_schema(tenant_id) do
    tenant_id_str = to_string(tenant_id)

    case TenantSchemas.schema_for_id(tenant_id_str) do
      nil ->
        Logger.error("Could not resolve tenant schema for tenant_id: #{tenant_id_str}")
        {:error, {:unknown_tenant, tenant_id_str}}

      schema ->
        {:ok, schema}
    end
  end

  defp encode_event(event) do
    with {:ok, id} <- dump_uuid(event[:id]),
         {:ok, tenant_id} <- dump_uuid(event[:tenant_id]) do
      {:ok, %{event | id: id, tenant_id: tenant_id}}
    end
  end

  defp dump_uuid(nil), do: {:ok, nil}

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> {:error, {:invalid_uuid, value}}
    end
  end

  @doc """
  Write an audit event asynchronously (fire and forget).

  Spawns a task to write the event. Errors are logged but not returned.
  """
  @spec write_async(opts()) :: :ok
  def write_async(opts) do
    Task.start(fn ->
      case write(opts) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("Async audit event write failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Build an OCSF event map without writing it.

  Useful for batch operations or testing.
  """
  @spec build_event(opts()) :: {:ok, map()} | {:error, term()}
  def build_event(opts) do
    with {:ok, tenant_id} <- fetch_required(opts, :tenant_id),
         {:ok, action} <- fetch_required(opts, :action),
         {:ok, resource_type} <- fetch_required(opts, :resource_type),
         {:ok, resource_id} <- fetch_required(opts, :resource_id) do
      resource_name = Keyword.get(opts, :resource_name)
      actor = Keyword.get(opts, :actor)
      details = Keyword.get(opts, :details, %{})
      severity = Keyword.get(opts, :severity, :informational)

      {activity_id, activity_name, action_verb} = activity_for_action(action)
      severity_id = severity_to_id(severity)

      message =
        Keyword.get(opts, :message) ||
          build_message(resource_type, resource_name, action_verb, actor)

      now = DateTime.utc_now()

      event = %{
        id: UUID.uuid4(),
        time: now,
        class_uid: OCSF.class_event_log_activity(),
        category_uid: OCSF.category_system_activity(),
        type_uid: OCSF.type_uid(OCSF.class_event_log_activity(), activity_id),
        activity_id: activity_id,
        activity_name: activity_name,
        severity_id: severity_id,
        severity: OCSF.severity_name(severity_id),
        message: message,
        status_id: OCSF.status_success(),
        status: "Success",
        status_code: nil,
        status_detail: nil,
        metadata:
          OCSF.build_metadata(
            version: "1.7.0",
            product_name: "ServiceRadar Core",
            correlation_uid: "#{resource_type}:#{resource_id}"
          ),
        observables: build_observables(resource_type, resource_id, resource_name),
        trace_id: nil,
        span_id: nil,
        actor: build_actor(actor),
        device: nil,
        src_endpoint: nil,
        log_name: resource_type,
        log_provider: "serviceradar.core",
        log_level: severity_to_level(severity),
        log_version: nil,
        unmapped: build_unmapped(resource_type, resource_id, action_verb, details),
        raw_data: nil,
        tenant_id: tenant_id,
        created_at: now
      }

      {:ok, event}
    end
  end

  # Private helpers

  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_required, key}}
    end
  end

  defp activity_for_action(:create), do: {OCSF.activity_log_create(), "Create", "created"}
  defp activity_for_action(:read), do: {OCSF.activity_log_read(), "Read", "accessed"}
  defp activity_for_action(:update), do: {OCSF.activity_log_update(), "Update", "updated"}
  defp activity_for_action(:delete), do: {OCSF.activity_log_delete(), "Delete", "deleted"}
  defp activity_for_action(:enable), do: {OCSF.activity_log_update(), "Update", "enabled"}
  defp activity_for_action(:disable), do: {OCSF.activity_log_update(), "Update", "disabled"}
  defp activity_for_action(:revoke), do: {OCSF.activity_log_update(), "Update", "revoked"}

  defp activity_for_action(action) when is_atom(action) do
    {OCSF.activity_log_update(), "Update", Atom.to_string(action)}
  end

  defp severity_to_id(:informational), do: OCSF.severity_informational()
  defp severity_to_id(:low), do: OCSF.severity_low()
  defp severity_to_id(:medium), do: OCSF.severity_medium()
  defp severity_to_id(:high), do: OCSF.severity_high()
  defp severity_to_id(:critical), do: OCSF.severity_critical()
  defp severity_to_id(_), do: OCSF.severity_informational()

  defp severity_to_level(:informational), do: "info"
  defp severity_to_level(:low), do: "notice"
  defp severity_to_level(:medium), do: "warning"
  defp severity_to_level(:high), do: "error"
  defp severity_to_level(:critical), do: "critical"
  defp severity_to_level(_), do: "info"

  defp build_message(resource_type, resource_name, action_verb, nil) do
    name_part = if resource_name, do: " '#{resource_name}'", else: ""
    "#{humanize(resource_type)}#{name_part} #{action_verb}"
  end

  defp build_message(resource_type, resource_name, action_verb, actor) do
    actor_email = Map.get(actor, :email, "system")
    name_part = if resource_name, do: " '#{resource_name}'", else: ""
    "#{humanize(resource_type)}#{name_part} #{action_verb} by #{actor_email}"
  end

  defp humanize(string) when is_binary(string) do
    string
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp build_observables(resource_type, resource_id, resource_name) do
    observables = [
      %{name: to_string(resource_id), type: "Resource UID", type_id: 99}
    ]

    observables =
      if resource_name do
        [%{name: resource_name, type: "Resource Name", type_id: 99} | observables]
      else
        observables
      end

    [%{name: resource_type, type: "Resource Type", type_id: 99} | observables]
  end

  defp build_actor(nil), do: nil

  defp build_actor(actor) when is_map(actor) do
    user =
      %{}
      |> maybe_put(:uid, actor[:id] || actor["id"] |> to_string_safe())
      |> maybe_put(:email_addr, actor[:email] || actor["email"])
      |> maybe_put(:name, actor[:email] || actor["email"])

    if map_size(user) > 0, do: %{user: user}, else: nil
  end

  defp build_actor(_), do: nil

  defp build_unmapped(resource_type, resource_id, action_verb, details) do
    base = %{
      "resource_type" => resource_type,
      "resource_id" => to_string(resource_id),
      "action" => action_verb
    }

    if is_map(details) and map_size(details) > 0 do
      Map.put(base, "details", stringify_keys(details))
    else
      base
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v) do
    Atom.to_string(v)
  end

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v), do: v

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_string_safe(nil), do: nil
  defp to_string_safe(value), do: to_string(value)
end
