defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData

  attr(:device_row, :map, default: nil)
  attr(:device_deleted, :boolean, default: false)
  attr(:editing, :boolean, default: false)
  attr(:snmp_polling_source, :map, default: nil)

  def device_summary_section(assigns) do
    ~H"""
    <div
      :if={is_map(@device_row) and not @editing}
      class="rounded-xl border border-sr-line bg-sr-surface p-4"
    >
      <div class="grid grid-cols-1 xl:grid-cols-3 gap-3">
        <div class="sr-ui-card bg-sr-surface border border-sr-line">
          <div class="sr-ui-card-body p-4 gap-2">
            <div class="flex items-center gap-2">
              <.icon name="hero-identification" class="size-4 text-sr-brand" />
              <h3 class="text-sm font-semibold">Identity</h3>
            </div>
            <div class="space-y-1 text-sm">
              <.kv_inline label="Hostname" value={Map.get(@device_row, "hostname")} />
              <.kv_inline label="IP" value={Map.get(@device_row, "ip")} mono />
              <.kv_inline label="Type" value={device_type_label(@device_row)} />
              <.kv_inline label="Vendor" value={Map.get(@device_row, "vendor_name")} />
              <.kv_inline
                :if={present?(Map.get(@device_row, "model"))}
                label="Model"
                value={Map.get(@device_row, "model")}
              />
              <.kv_inline
                label="Classification"
                value={classification_provenance_label(@device_row)}
              />
              <.kv_inline
                :if={agent_device?(@device_row)}
                label="Agent"
                value={agent_label(@device_row)}
                mono
              />
            </div>
          </div>
        </div>

        <div class="sr-ui-card bg-sr-surface border border-sr-line">
          <div class="sr-ui-card-body p-4 gap-2">
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <.icon name="hero-signal" class="size-4 text-info" />
                <h3 class="text-sm font-semibold">SNMP</h3>
              </div>
              <.ui_badge
                :if={is_map(@snmp_polling_source)}
                size="xs"
                variant={polling_source_variant(@snmp_polling_source.source)}
              >
                {@snmp_polling_source.source_label}
              </.ui_badge>
            </div>
            <div class="space-y-1 text-sm">
              <.kv_inline
                label="SNMP Name"
                value={snmp_metadata_value(@device_row, "snmp_name", "sys_name")}
              />
              <.kv_inline
                label="SNMP Owner"
                value={snmp_owner(@device_row)}
              />
              <.kv_inline
                label="SNMP Location"
                value={snmp_metadata_value(@device_row, "snmp_location", "sys_location")}
              />
              <.kv_inline
                label="SNMP Description"
                value={snmp_metadata_value(@device_row, "snmp_description", "sys_descr")}
              />
            </div>
            <.snmp_polling_source_block source={@snmp_polling_source} />
          </div>
        </div>

        <div class="sr-ui-card bg-sr-surface border border-sr-line">
          <div class="sr-ui-card-body p-4 gap-2">
            <div class="flex items-center gap-2">
              <.icon name="hero-clock" class="size-4 text-success" />
              <h3 class="text-sm font-semibold">Status</h3>
            </div>
            <div class="space-y-1 text-sm">
              <.kv_inline
                :if={present?(Map.get(@device_row, "gateway_id"))}
                label="Gateway"
                value={Map.get(@device_row, "gateway_id")}
                mono
              />
              <.kv_inline
                label="Added"
                value={format_timestamp(device_added_at(@device_row))}
                mono
              />
              <.kv_inline
                label="Last Seen"
                value={
                  format_timestamp(
                    Map.get(@device_row, "last_seen") || Map.get(@device_row, "last_seen_time")
                  )
                }
                mono
              />
              <.kv_inline
                :if={@device_deleted}
                label="Deleted At"
                value={Map.get(@device_row, "deleted_at")}
                mono
              />
              <.kv_inline
                :if={@device_deleted and present?(Map.get(@device_row, "deleted_by"))}
                label="Deleted By"
                value={Map.get(@device_row, "deleted_by")}
              />
              <.kv_inline
                :if={@device_deleted and present?(Map.get(@device_row, "deleted_reason"))}
                label="Deleted Reason"
                value={Map.get(@device_row, "deleted_reason")}
              />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:source, :map, default: nil)

  defp snmp_polling_source_block(assigns) do
    ~H"""
    <div
      :if={is_map(@source)}
      class="mt-3 space-y-1 border-t border-sr-line pt-3 text-sm"
      data-testid="snmp-polling-source"
    >
      <div class="text-xs font-semibold uppercase tracking-wide text-sr-muted">Polling</div>
      <div class="flex items-start gap-2">
        <span class="shrink-0 text-sr-muted">Profile:</span>
        <.link
          :if={is_binary(@source.profile_href) and present?(@source.profile_name)}
          href={@source.profile_href}
          class="link link-hover min-w-0 flex-1 break-words"
        >
          {@source.profile_name}
        </.link>
        <span
          :if={is_nil(@source.profile_href) or not present?(@source.profile_name)}
          class="text-sr-ink"
        >
          {format_value(@source.profile_name)}
        </span>
      </div>
      <.kv_inline
        :if={present?(@source.target_query)}
        label="Matched by"
        value={@source.target_query}
        mono
      />
      <.kv_inline label="Credential" value={@source.credential_label} />
      <.kv_inline :if={present?(@source.version)} label="Version" value={@source.version} />
      <.kv_inline
        :if={is_integer(@source.poll_interval)}
        label="Interval"
        value={"#{@source.poll_interval}s"}
      />
      <p
        :if={@source.source != :none and not @source.credential_configured?}
        class="text-xs text-warning"
      >
        No community or secret is attached, so this device will not be polled.
      </p>
      <p :if={@source.profile_enabled == false} class="text-xs text-warning">
        This profile is disabled.
      </p>
      <.link href={@source.settings_href} class="link link-hover text-xs">
        Manage SNMP profiles
      </.link>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  def kv_inline(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <span class="shrink-0 text-sr-muted">{@label}:</span>
      <span class={[
        "min-w-0 flex-1 break-words whitespace-normal text-sr-ink",
        @mono && "font-mono text-xs"
      ]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp polling_source_variant(:device_override), do: "warning"
  defp polling_source_variant(:profile), do: "primary"
  defp polling_source_variant(:default_profile), do: "info"
  defp polling_source_variant(_), do: "ghost"

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp metadata_value(row, key) when is_map(row) and is_binary(key) do
    row
    |> row_metadata()
    |> Map.get(key)
  end

  defp metadata_value(_row, _key), do: nil

  defp snmp_metadata_value(row, primary_key, fallback_key) when is_map(row) do
    metadata_value(row, primary_key) || metadata_value(row, fallback_key)
  end

  defp snmp_metadata_value(_row, _primary_key, _fallback_key), do: nil

  defp snmp_owner(row) when is_map(row) do
    owner_name =
      case Map.get(row, "owner") do
        %{"name" => name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    owner_name ||
      metadata_value(row, "snmp_owner") ||
      metadata_value(row, "sys_owner") ||
      metadata_value(row, "sys_contact")
  end

  defp snmp_owner(_row), do: nil

  defp classification_provenance_label(row) when is_map(row) do
    source = row |> metadata_value("classification_source") |> normalize_metadata_source()
    rule_id = metadata_value(row, "classification_rule_id")

    cond do
      present?(rule_id) ->
        "Rule-based (#{rule_id})"

      source in ["snmp_fallback", "snmp_fingerprint_fallback"] or snmp_fallback_derived?(row) ->
        "SNMP fallback-derived"

      true ->
        "Unspecified"
    end
  end

  defp classification_provenance_label(_row), do: "Unspecified"

  defp device_type_label(row) when is_map(row) do
    first_present([
      Map.get(row, "type"),
      metadata_value(row, "armis_type"),
      metadata_value(row, "device_type"),
      metadata_value(row, "type"),
      metadata_value(row, "armis_category"),
      metadata_value(row, "category"),
      device_type_name(Map.get(row, "type_id"))
    ])
  end

  defp device_type_label(_row), do: nil

  defp device_type_name(0), do: "Unknown"
  defp device_type_name(1), do: "Server"
  defp device_type_name(2), do: "Desktop"
  defp device_type_name(3), do: "Laptop"
  defp device_type_name(4), do: "Tablet"
  defp device_type_name(5), do: "Mobile"
  defp device_type_name(6), do: "Virtual"
  defp device_type_name(7), do: "IOT"
  defp device_type_name(8), do: "Browser"
  defp device_type_name(9), do: "Firewall"
  defp device_type_name(10), do: "Switch"
  defp device_type_name(11), do: "Hub"
  defp device_type_name(12), do: "Router"
  defp device_type_name(13), do: "IDS"
  defp device_type_name(14), do: "IPS"
  defp device_type_name(15), do: "Load Balancer"
  defp device_type_name(99), do: "Other"
  defp device_type_name(_type_id), do: nil

  defp snmp_fallback_derived?(row) when is_map(row) do
    metadata = row_metadata(row)
    has_rule = present?(metadata_value(row, "classification_rule_id"))

    has_display_values =
      present?(Map.get(row, "type")) or present?(Map.get(row, "vendor_name")) or
        present?(Map.get(row, "model"))

    has_snmp_evidence =
      is_map(Map.get(metadata, "snmp_fingerprint")) or
        present?(Map.get(metadata, "sys_object_id")) or
        present?(Map.get(metadata, "sys_descr")) or
        present?(Map.get(metadata, "sys_name")) or
        present?(Map.get(metadata, "snmp_description")) or
        present?(Map.get(metadata, "snmp_name")) or
        present?(Map.get(metadata, "ip_forwarding"))

    not has_rule and has_display_values and has_snmp_evidence
  end

  defp normalize_metadata_source(nil), do: ""

  defp normalize_metadata_source(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn
      nil -> nil
      "" -> nil
      value -> value
    end)
  end

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(value) do
    case parse_datetime(value) do
      {:ok, %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end

  defp device_added_at(row) when is_map(row) do
    first_present([
      Map.get(row, "first_seen"),
      Map.get(row, "first_seen_time"),
      Map.get(row, :first_seen),
      Map.get(row, :first_seen_time)
    ])
  end

  defp device_added_at(_row), do: nil

  # Agent status comes from the ocsf_agents linkage resolved at load time
  # (DeviceStateData.tag_agent_device/2); the OCSF agent_list column is dead.
  defp agent_device?(row), do: DeviceStateData.agent?(row)

  defp agent_label(row) do
    case DeviceStateData.agent_labels(row) do
      [label | _rest] -> label
      _ -> "Agent"
    end
  end
end
