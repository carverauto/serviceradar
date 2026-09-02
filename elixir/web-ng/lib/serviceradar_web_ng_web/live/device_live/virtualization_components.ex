defmodule ServiceRadarWebNGWeb.DeviceLive.VirtualizationComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Helpers.VirtualizationLabels

  # ---------------------------------------------------------------------------
  # Virtualization Section
  # ---------------------------------------------------------------------------

  attr(:summary, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def virtualization_guests_tab(assigns) do
    guests =
      case assigns.summary do
        summary when is_map(summary) -> Map.get(summary, :guests, [])
        _ -> []
      end

    running_count = Enum.count(guests, &(to_string(&1.status) == "running"))

    assigns =
      assigns
      |> assign(:guests, guests)
      |> assign(:running_count, running_count)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-squares-2x2" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Guests</span>
          <span class="rounded-full bg-sr-brand/10 px-2 py-0.5 text-[11px] font-semibold text-sr-brand">
            {length(@guests)} total
          </span>
        </div>
        <span class="text-xs text-sr-muted">{@running_count} running</span>
      </div>

      <div class="sr-ui-table-shell">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>VMID</th>
              <th>Status</th>
              <th class="text-right">CPU</th>
              <th class="text-right">Memory</th>
              <th class="text-right">Disk</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={guest <- @guests}>
              <td class="font-medium">{guest.name || guest.provider_ref}</td>
              <td>{virtualization_guest_type_label(guest.guest_type)}</td>
              <td class="font-mono">{guest.vmid || "—"}</td>
              <td><.virtualization_health_badge value={guest.status} /></td>
              <td class="text-right font-mono">{format_virtualization_pct(guest.cpu_ratio)}</td>
              <td class="text-right font-mono">
                {format_bytes(guest.memory_used_bytes)}
                <span class="text-sr-muted">/ {format_bytes(guest.memory_total_bytes)}</span>
              </td>
              <td class="text-right font-mono">
                {virtualization_guest_disk_value(guest)}
                <span class="text-sr-muted">{virtualization_guest_disk_subvalue(guest)}</span>
              </td>
              <td class="text-right">
                <.ui_button
                  :if={is_binary(guest.device_uid) and guest.device_uid != ""}
                  navigate={~p"/devices/#{guest.device_uid}"}
                  size="xs"
                  variant="ghost"
                >
                  Open
                </.ui_button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr(:summary, :map, required: true)
  attr(:timezone, :string, default: "Etc/UTC")

  def virtualization_section(assigns) do
    summary = assigns.summary
    host = Map.get(summary, :host)
    parent_host = Map.get(summary, :parent_host)
    cluster = Map.get(summary, :cluster)
    guest = Map.get(summary, :guest)
    datastores = Map.get(summary, :datastores, [])
    disks = Map.get(summary, :disks, [])
    network_interfaces = Map.get(summary, :network_interfaces, [])
    storage_systems = Map.get(summary, :storage_systems, [])
    guests = Map.get(summary, :guests, [])
    storage_total = Enum.sum(Enum.map(datastores, &(&1.total_bytes || 0)))
    storage_used = Enum.sum(Enum.map(datastores, &(&1.used_bytes || 0)))
    storage_pct = percent_of(storage_used, storage_total)
    running_guests = Enum.count(guests, &(to_string(&1.status) == "running"))
    ceph = Enum.find(storage_systems, &(to_string(&1.storage_system_type) == "ceph"))
    observed_at = observed_at_for_virtualization(host, guest)
    provider_label = VirtualizationLabels.provider_label(host || guest)

    assigns =
      assigns
      |> assign(:host, host)
      |> assign(:parent_host, parent_host)
      |> assign(:parent_host_uid, parent_host_uid(parent_host))
      |> assign(:parent_host_label, parent_host_label(parent_host, guest))
      |> assign(:cluster, cluster)
      |> assign(:guest, guest)
      |> assign(:datastores, datastores)
      |> assign(:disks, disks)
      |> assign(:network_interfaces, network_interfaces)
      |> assign(:storage_systems, storage_systems)
      |> assign(:guests, guests)
      |> assign(:storage_total, storage_total)
      |> assign(:storage_used, storage_used)
      |> assign(:storage_pct, storage_pct)
      |> assign(:running_guests, running_guests)
      |> assign(:ceph, ceph)
      |> assign(:observed_at, observed_at)
      |> assign(:provider_label, provider_label)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-server-stack" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Virtualization</span>
          <span class="rounded-full bg-sr-brand/10 px-2 py-0.5 text-[11px] font-semibold text-sr-brand">
            {@provider_label}
          </span>
        </div>
        <.user_time
          id={"device-virtualization-#{virtualization_time_key(@host, @guest)}-observed-at"}
          value={@observed_at}
          timezone={@timezone}
          style={:compact}
          class="text-xs text-sr-muted font-mono"
        />
      </div>

      <div class="p-4 space-y-4">
        <div :if={@host} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-3">
          <.virtualization_stat
            icon="hero-cpu-chip"
            label="CPU"
            value={format_virtualization_pct(@host.cpu_ratio)}
            subvalue={@host.status}
          />
          <.virtualization_stat
            icon="hero-circle-stack"
            label="Memory"
            value={format_bytes(@host.memory_used_bytes)}
            subvalue={"of #{format_bytes(@host.memory_total_bytes)}"}
          />
          <.virtualization_stat
            icon="hero-square-3-stack-3d"
            label="Storage"
            value={format_bytes(@storage_used)}
            subvalue={"#{format_pct(@storage_pct)}% of #{format_bytes(@storage_total)}"}
          />
          <.virtualization_stat
            icon="hero-squares-2x2"
            label="Guests"
            value={Integer.to_string(length(@guests))}
            subvalue={"#{@running_guests} running"}
          />
        </div>

        <div :if={@cluster} class="rounded-lg border border-sr-line bg-sr-subtle/30 px-3 py-2">
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex items-center gap-2">
              <.icon name="hero-cube-transparent" class="size-4 text-info" />
              <span class="truncate text-sm font-medium">{@cluster.name}</span>
            </div>
            <div class="flex items-center gap-2">
              <span :if={@cluster.version} class="font-mono text-xs text-sr-muted">
                {@cluster.version}
              </span>
              <.virtualization_health_badge value={@cluster.status} />
            </div>
          </div>
        </div>

        <div :if={@guest} class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-3">
          <.virtualization_stat
            icon="hero-squares-2x2"
            label="Guest Type"
            value={virtualization_guest_type_label(@guest.guest_type)}
            subvalue={@guest.status}
          />
          <.virtualization_stat
            icon="hero-cpu-chip"
            label="CPU"
            value={format_virtualization_pct(@guest.cpu_ratio)}
          />
          <.virtualization_stat
            icon="hero-circle-stack"
            label="Memory"
            value={format_bytes(@guest.memory_used_bytes)}
            subvalue={"of #{format_bytes(@guest.memory_total_bytes)}"}
          />
          <.virtualization_stat
            icon="hero-square-3-stack-3d"
            label="Disk"
            value={virtualization_guest_disk_value(@guest)}
            subvalue={virtualization_guest_disk_subvalue(@guest)}
          />
        </div>

        <div
          :if={@guest && @parent_host_label}
          class="rounded-lg border border-sr-line bg-sr-subtle/30 px-3 py-2"
        >
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0 flex items-center gap-2">
              <.icon name="hero-server-stack" class="size-4 text-info" />
              <span class="text-xs text-sr-muted">Hypervisor</span>
              <span class="truncate text-sm font-medium">{@parent_host_label}</span>
            </div>
            <.ui_button
              :if={@parent_host_uid}
              navigate={~p"/devices/#{@parent_host_uid}"}
              size="xs"
              variant="ghost"
            >
              Open node
            </.ui_button>
          </div>
        </div>

        <div :if={@ceph} class="rounded-lg border border-sr-line bg-sr-subtle/30 px-3 py-2">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-circle-stack" class="size-4 text-info" />
              <span class="text-sm font-medium">Ceph</span>
            </div>
            <.virtualization_health_badge value={@ceph.health || @ceph.status} />
          </div>
        </div>

        <div :if={@datastores != []} class="space-y-2">
          <h4 class="text-xs font-semibold uppercase text-sr-muted">Datastores</h4>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "xs")}>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Type</th>
                  <th>Status</th>
                  <th class="text-right">Used</th>
                  <th class="text-right">Total</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={store <- Enum.take(@datastores, 8)}>
                  <td class="font-medium">{store.name}</td>
                  <td>{store.storage_type || "—"}</td>
                  <td>
                    <.ui_badge
                      size="xs"
                      variant={if(store.active, do: "success", else: "ghost")}
                    >
                      {virtualization_datastore_status(store)}
                    </.ui_badge>
                  </td>
                  <td class="text-right font-mono">{format_bytes(store.used_bytes)}</td>
                  <td class="text-right font-mono">{format_bytes(store.total_bytes)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={@disks != []} class="space-y-2">
          <h4 class="text-xs font-semibold uppercase text-sr-muted">Host Disks</h4>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "xs")}>
              <thead>
                <tr>
                  <th>Path</th>
                  <th>Model</th>
                  <th>Type</th>
                  <th>Health</th>
                  <th class="text-right">Size</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={disk <- Enum.take(@disks, 8)}>
                  <td class="font-mono">{disk.path || disk.by_id || "—"}</td>
                  <td>{disk.model || "—"}</td>
                  <td>{disk.disk_type || "—"}</td>
                  <td><.virtualization_health_badge value={disk.health} /></td>
                  <td class="text-right font-mono">{format_bytes(disk.size_bytes)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={@network_interfaces != []} class="space-y-2">
          <h4 class="text-xs font-semibold uppercase text-sr-muted">Network</h4>
          <div class="sr-ui-table-shell">
            <table class={ui_table_class(size: "xs")}>
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Type</th>
                  <th>State</th>
                  <th>Address</th>
                  <th>Bridge Ports</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={iface <- Enum.take(@network_interfaces, 8)}>
                  <td class="font-medium">{iface.name}</td>
                  <td>{iface.interface_type || "—"}</td>
                  <td>
                    <.ui_badge
                      size="xs"
                      variant={if(iface.active, do: "success", else: "ghost")}
                    >
                      {if iface.active, do: "active", else: "inactive"}
                    </.ui_badge>
                  </td>
                  <td class="font-mono">{virtualization_interface_address(iface)}</td>
                  <td>{iface.bridge_ports || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:subvalue, :string, default: nil)

  defp virtualization_stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-subtle/30 p-3">
      <div class="flex items-center gap-2 text-xs text-sr-muted">
        <.icon name={@icon} class="size-4" />
        <span>{@label}</span>
      </div>
      <div class="mt-2 text-lg font-semibold">{@value}</div>
      <div :if={present?(@subvalue)} class="text-xs text-sr-muted">{@subvalue}</div>
    </div>
    """
  end

  attr(:value, :any, default: nil)

  defp virtualization_health_badge(assigns) do
    label = assigns.value |> to_string() |> String.trim() |> blank_to_value("unknown")

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, virtualization_health_variant(label))

    ~H"""
    <.ui_badge size="xs" variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp observed_at_for_virtualization(%{observed_at: observed_at}, _guest), do: observed_at
  defp observed_at_for_virtualization(_host, %{observed_at: observed_at}), do: observed_at
  defp observed_at_for_virtualization(_host, _guest), do: nil

  # device_uid to link the guest back to its parent hypervisor node device.
  defp parent_host_uid(%{device_uid: uid}) when is_binary(uid) and uid != "", do: uid
  defp parent_host_uid(_parent_host), do: nil

  # Human label for the parent hypervisor: prefer the host's node name, then its
  # device_uid, then the node name embedded in the guest's provider_ref.
  defp parent_host_label(%{name: name}, _guest) when is_binary(name) and name != "", do: name
  defp parent_host_label(%{device_uid: uid}, _guest) when is_binary(uid) and uid != "", do: uid

  defp parent_host_label(_parent_host, %{provider_ref: ref}) when is_binary(ref) do
    case String.split(ref, ":") do
      [_provider, "node", node | _] when node != "" -> node
      _ -> nil
    end
  end

  defp parent_host_label(_parent_host, _guest), do: nil

  defp percent_of(_used, total) when total in [nil, 0], do: nil
  defp percent_of(used, total) when is_number(used) and is_number(total), do: used / total * 100.0
  defp percent_of(_used, _total), do: nil

  defp format_virtualization_pct(value) when is_number(value), do: "#{format_pct(value * 100.0)}%"
  defp format_virtualization_pct(_value), do: "—"

  defp virtualization_guest_type_label("vm"), do: "VM"
  defp virtualization_guest_type_label("container"), do: "LXC"
  defp virtualization_guest_type_label(value) when is_binary(value), do: String.upcase(value)
  defp virtualization_guest_type_label(_value), do: "Guest"

  defp virtualization_guest_disk_value(%{disk_used_bytes: used}) when is_integer(used) and used > 0 do
    format_bytes(used)
  end

  defp virtualization_guest_disk_value(%{disk_total_bytes: total}) when is_integer(total) and total > 0 do
    "Usage unavailable"
  end

  defp virtualization_guest_disk_value(_guest), do: "—"

  defp virtualization_guest_disk_subvalue(%{disk_used_bytes: used, disk_total_bytes: total})
       when is_integer(used) and used > 0 and is_integer(total) and total > 0 do
    "of #{format_bytes(total)}"
  end

  defp virtualization_guest_disk_subvalue(%{disk_total_bytes: total}) when is_integer(total) and total > 0 do
    "provisioned #{format_bytes(total)}"
  end

  defp virtualization_guest_disk_subvalue(_guest), do: nil

  defp virtualization_datastore_status(%{active: true, enabled: false}), do: "disabled"
  defp virtualization_datastore_status(%{active: true}), do: "active"
  defp virtualization_datastore_status(%{enabled: false}), do: "disabled"
  defp virtualization_datastore_status(_store), do: "inactive"

  defp virtualization_interface_address(%{ip_addresses: [first | rest]}) when is_binary(first) do
    suffix = if rest == [], do: "", else: " +#{length(rest)}"
    "#{first}#{suffix}"
  end

  defp virtualization_interface_address(%{address: address}) when is_binary(address) and address != "", do: address

  defp virtualization_interface_address(%{cidr: cidr}) when is_binary(cidr) and cidr != "", do: cidr

  defp virtualization_interface_address(_iface), do: "—"

  def virtualization_guests?(%{guests: guests}) when is_list(guests), do: guests != []
  def virtualization_guests?(_summary), do: false

  defp virtualization_health_variant(value) do
    normalized = value |> to_string() |> String.downcase()

    cond do
      normalized in ["passed", "ok", "health_ok", "online"] ->
        "success"

      String.contains?(normalized, "warn") ->
        "warning"

      String.contains?(normalized, "fail") or String.contains?(normalized, "crit") ->
        "error"

      true ->
        "ghost"
    end
  end

  defp blank_to_value("", fallback), do: fallback
  defp blank_to_value(nil, fallback), do: fallback
  defp blank_to_value(value, _fallback), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp virtualization_time_key(host, guest) do
    candidate =
      case host || guest do
        %{device_uid: value} when is_binary(value) and value != "" -> value
        %{provider_ref: value} when is_binary(value) and value != "" -> value
        %{name: value} when is_binary(value) and value != "" -> value
        _ -> "resource"
      end

    candidate
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_pct(value) when is_integer(value), do: Integer.to_string(value)
  defp format_pct(_), do: "—"

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776 * 1.0, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824 * 1.0, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576 * 1.0, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024 * 1.0, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"
end
