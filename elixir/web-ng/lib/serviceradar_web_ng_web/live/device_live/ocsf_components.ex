defmodule ServiceRadarWebNGWeb.DeviceLive.OcsfComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents, only: [metadata_lookup: 2]
  # ---------------------------------------------------------------------------
  # OCSF Information Section (OS, Hardware, Network, Compliance)
  # ---------------------------------------------------------------------------

  attr(:device_row, :map, required: true)

  def ocsf_info_section(assigns) do
    assigns = assign_ocsf_info(assigns)

    ~H"""
    <div :if={@has_any} class="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <.hw_info_card :if={@has_hw} hw_info={@hw_info} />
      <.compliance_card
        :if={@has_compliance}
        risk_level={@risk_level}
        risk_score={@risk_score}
        is_active={@is_active}
        is_managed={@is_managed}
        is_compliant={@is_compliant}
        is_trusted={@is_trusted}
      />
    </div>
    """
  end

  defp assign_ocsf_info(assigns) do
    metadata = row_metadata(assigns.device_row)
    hw_info = Map.get(assigns.device_row, "hw_info")

    risk_score =
      normalize_risk_score(
        Map.get(assigns.device_row, "risk_score") ||
          metadata_first_value(metadata, ["armis_risk_score", "risk_score"])
      )

    risk_level =
      Map.get(assigns.device_row, "risk_level") ||
        metadata_lookup(metadata, "armis_risk_level") ||
        risk_level_from_score(risk_score)

    is_managed = Map.get(assigns.device_row, "is_managed")
    is_compliant = Map.get(assigns.device_row, "is_compliant")
    is_trusted = Map.get(assigns.device_row, "is_trusted")
    is_active = device_active_state(assigns.device_row, metadata)
    has_hw = map_present?(hw_info)

    has_compliance =
      compliance_present?(risk_level, risk_score, is_active, is_managed, is_compliant)

    has_any = has_hw or has_compliance

    assigns
    |> assign(:hw_info, hw_info)
    |> assign(:risk_level, risk_level)
    |> assign(:risk_score, risk_score)
    |> assign(:is_active, is_active)
    |> assign(:is_managed, is_managed)
    |> assign(:is_compliant, is_compliant)
    |> assign(:is_trusted, is_trusted)
    |> assign(:has_hw, has_hw)
    |> assign(:has_compliance, has_compliance)
    |> assign(:has_any, has_any)
  end

  defp map_present?(value), do: is_map(value) and map_size(value) > 0

  defp compliance_present?(risk_level, risk_score, is_active, is_managed, is_compliant) do
    not is_nil(risk_level) or not is_nil(risk_score) or not is_nil(is_active) or
      not is_nil(is_managed) or not is_nil(is_compliant)
  end

  def device_active_state(row, metadata) when is_map(row) do
    row
    |> Map.get("is_active")
    |> normalize_bool()
    |> case do
      nil ->
        metadata
        |> metadata_first_value(["armis_is_active", "is_active", "active", "in_service"])
        |> normalize_bool()

      value ->
        value
    end
  end

  def device_active_state(_row, metadata) do
    metadata
    |> metadata_first_value(["armis_is_active", "is_active", "active", "in_service"])
    |> normalize_bool()
  end

  defp normalize_bool(value) when is_boolean(value), do: value
  defp normalize_bool(1), do: true
  defp normalize_bool(0), do: false

  defp normalize_bool(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["true", "yes", "y", "1", "active", "in_service", "in-service"] ->
        true

      value
      when value in ["false", "no", "n", "0", "inactive", "out_of_service", "out-of-service"] ->
        false

      _ ->
        nil
    end
  end

  defp normalize_bool(_), do: nil

  attr(:hw_info, :map, required: true)

  defp hw_info_card(assigns) do
    ram_size = Map.get(assigns.hw_info, "ram_size")
    ram_display = if is_number(ram_size), do: format_bytes(ram_size)

    assigns = assign(assigns, :ram_display, ram_display)

    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-server" class="size-4 text-success" />
          <span class="text-sm font-semibold">Hardware Info</span>
        </div>
      </div>
      <div class="p-4">
        <div class="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
          <.kv_block
            :if={Map.get(@hw_info, "cpu_type")}
            label="CPU Type"
            value={Map.get(@hw_info, "cpu_type")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_architecture")}
            label="Architecture"
            value={Map.get(@hw_info, "cpu_architecture")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_cores")}
            label="CPU Cores"
            value={Map.get(@hw_info, "cpu_cores")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_count")}
            label="CPU Count"
            value={Map.get(@hw_info, "cpu_count")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "cpu_speed_mhz")}
            label="CPU Speed"
            value={"#{Map.get(@hw_info, "cpu_speed_mhz")} MHz"}
          />
          <.kv_block :if={@ram_display} label="RAM" value={@ram_display} />
          <.kv_block
            :if={Map.get(@hw_info, "serial_number")}
            label="Serial"
            value={Map.get(@hw_info, "serial_number")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "chassis")}
            label="Chassis"
            value={Map.get(@hw_info, "chassis")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "bios_manufacturer")}
            label="BIOS Vendor"
            value={Map.get(@hw_info, "bios_manufacturer")}
          />
          <.kv_block
            :if={Map.get(@hw_info, "bios_ver")}
            label="BIOS Version"
            value={Map.get(@hw_info, "bios_ver")}
          />
        </div>
      </div>
    </div>
    """
  end

  attr(:risk_level, :string, default: nil)
  attr(:risk_score, :any, default: nil)
  attr(:is_active, :boolean, default: nil)
  attr(:is_managed, :boolean, default: nil)
  attr(:is_compliant, :boolean, default: nil)
  attr(:is_trusted, :boolean, default: nil)

  defp compliance_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-200 bg-base-100">
      <div class="px-4 py-3 border-b border-base-200">
        <div class="flex items-center gap-2">
          <.icon name="hero-shield-check" class="size-4 text-warning" />
          <span class="text-sm font-semibold">Risk & Compliance</span>
        </div>
      </div>
      <div class="p-4">
        <div class="flex flex-wrap items-center gap-4">
          <.risk_score_radial :if={not is_nil(@risk_score)} score={@risk_score} />
          <div :if={@risk_level} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Risk Level:</span>
            <.risk_badge level={@risk_level} />
          </div>
          <div :if={not is_nil(@is_active)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">In Service:</span>
            <.bool_badge value={@is_active} />
          </div>
          <div :if={not is_nil(@is_managed)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Managed:</span>
            <.bool_badge value={@is_managed} />
          </div>
          <div :if={not is_nil(@is_compliant)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Compliant:</span>
            <.bool_badge value={@is_compliant} />
          </div>
          <div :if={not is_nil(@is_trusted)} class="flex items-center gap-2">
            <span class="text-xs text-base-content/60">Trusted:</span>
            <.bool_badge value={@is_trusted} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:score, :any, required: true)

  defp risk_score_radial(assigns) do
    score = normalize_risk_score(assigns.score)
    max_score = risk_score_max(score)
    percent = risk_score_percent(score, max_score)
    color = risk_score_color(score, max_score)

    assigns =
      assigns
      |> assign(:score_display, format_risk_score(score))
      |> assign(:max_display, format_risk_score(max_score))
      |> assign(:percent, percent)
      |> assign(:color, color)

    ~H"""
    <div class="flex items-center gap-3">
      <div
        class="relative size-16 rounded-full"
        style={"background: conic-gradient(#{@color} #{@percent}%, hsl(var(--b2)) 0)"}
        aria-label={"Risk score #{@score_display} out of #{@max_display}"}
      >
        <div class="absolute inset-1.5 rounded-full bg-base-100 flex flex-col items-center justify-center">
          <span class="text-base font-semibold tabular-nums leading-none">{@score_display}</span>
          <span class="text-[10px] text-base-content/50 leading-none">/{@max_display}</span>
        </div>
      </div>
      <div class="min-w-0">
        <div class="text-xs text-base-content/60">Risk Score</div>
        <div class="text-sm font-semibold tabular-nums">{@score_display} / {@max_display}</div>
      </div>
    </div>
    """
  end

  defp normalize_risk_score(nil), do: nil

  defp normalize_risk_score(value) when is_integer(value), do: value

  defp normalize_risk_score(value) when is_float(value), do: value

  defp normalize_risk_score(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, ".") ->
        case Float.parse(value) do
          {score, _rest} -> score
          :error -> nil
        end

      true ->
        case Integer.parse(value) do
          {score, _rest} -> score
          :error -> nil
        end
    end
  end

  defp normalize_risk_score(_value), do: nil

  defp risk_score_max(score) when is_number(score) and score > 10, do: 100
  defp risk_score_max(_score), do: 10

  defp risk_score_percent(nil, _max_score), do: 0

  defp risk_score_percent(score, max_score) do
    score
    |> Kernel./(max_score)
    |> Kernel.*(100)
    |> round()
    |> max(0)
    |> min(100)
  end

  defp risk_score_color(score, max_score) do
    percent = risk_score_percent(score, max_score)

    cond do
      percent >= 70 -> "#ef4444"
      percent >= 40 -> "#f59e0b"
      true -> "#22c55e"
    end
  end

  defp risk_level_from_score(nil), do: nil

  defp risk_level_from_score(score) do
    percent = risk_score_percent(score, risk_score_max(score))

    cond do
      percent >= 90 -> "Critical"
      percent >= 70 -> "High"
      percent >= 40 -> "Medium"
      true -> "Low"
    end
  end

  defp format_risk_score(score) when is_integer(score), do: Integer.to_string(score)

  defp format_risk_score(score) when is_float(score) do
    score
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  attr(:level, :string, required: true)

  defp risk_badge(assigns) do
    variant =
      case assigns.level do
        "Critical" -> "error"
        "High" -> "warning"
        "Medium" -> "info"
        "Low" -> "success"
        _ -> "ghost"
      end

    assigns = assign(assigns, :variant, variant)

    ~H"""
    <.ui_badge size="sm" variant={@variant}>{@level}</.ui_badge>
    """
  end

  attr(:value, :boolean, required: true)

  defp bool_badge(assigns) do
    {label, variant} = if assigns.value, do: {"Yes", "success"}, else: {"No", "error"}
    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge size="sm" variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp metadata_first_value(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)

  defp kv_block(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs text-base-content/50">{@label}</span>
      <span class="text-sm font-medium break-words">{@value}</span>
    </div>
    """
  end

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"
end
