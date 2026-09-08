defmodule ServiceRadarWebNGWeb.DeviceLive.OcsfComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents, only: [metadata_lookup: 2]

  alias ServiceRadar.Inventory.EndpointVulnerabilityAssessment
  # ---------------------------------------------------------------------------
  # OCSF Information Section (OS, Hardware, Network, Compliance)
  # ---------------------------------------------------------------------------

  attr(:device_row, :map, required: true)
  attr(:vulnerability_assessments, :any, default: %{})

  def ocsf_info_section(assigns) do
    assigns = assign_ocsf_info(assigns)

    ~H"""
    <div :if={@has_any} class="space-y-4">
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

    stored_score =
      normalize_risk_score(
        Map.get(assigns.device_row, "risk_score") ||
          metadata_first_value(metadata, ["armis_risk_score", "risk_score"])
      )

    vuln_score = vulnerability_risk_score(assigns[:vulnerability_assessments] || %{})

    risk_score =
      cond do
        is_number(stored_score) and stored_score > 0 -> stored_score
        is_number(vuln_score) and vuln_score > 0 -> vuln_score
        true -> stored_score
      end

    stored_level =
      Map.get(assigns.device_row, "risk_level") ||
        metadata_lookup(metadata, "armis_risk_level")

    risk_level =
      cond do
        is_number(vuln_score) and vuln_score > 0 and (is_nil(stored_score) or stored_score == 0) ->
          vulnerability_risk_level(vuln_score)

        is_binary(stored_level) and stored_level != "" ->
          stored_level

        true ->
          risk_level_from_score(risk_score)
      end

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
    <div class="rounded-xl border border-sr-line bg-sr-surface">
      <div class="px-4 py-3 border-b border-sr-line">
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
    <div
      data-role="risk-compliance-card"
      class="w-full rounded-xl border border-sr-line bg-sr-surface"
    >
      <div class="border-b border-sr-line px-4 py-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-shield-check" class="size-4 text-warning" />
          <span class="text-sm font-semibold">Risk & Compliance</span>
        </div>
      </div>
      <div class="flex flex-wrap items-center gap-6 p-4 sm:gap-8">
        <.risk_score_radial :if={not is_nil(@risk_score)} score={@risk_score} />
        <div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-6 gap-y-3">
          <div :if={@risk_level} class="flex items-center gap-2">
            <span class="text-xs text-sr-muted">Risk Level</span>
            <.risk_badge level={@risk_level} />
          </div>
          <div :if={not is_nil(@is_active)} class="flex items-center gap-2">
            <span class="text-xs text-sr-muted">In Service</span>
            <.bool_badge value={@is_active} />
          </div>
          <div :if={not is_nil(@is_managed)} class="flex items-center gap-2">
            <span class="text-xs text-sr-muted">Managed</span>
            <.bool_badge value={@is_managed} />
          </div>
          <div :if={not is_nil(@is_compliant)} class="flex items-center gap-2">
            <span class="text-xs text-sr-muted">Compliant</span>
            <.bool_badge value={@is_compliant} />
          </div>
          <div :if={not is_nil(@is_trusted)} class="flex items-center gap-2">
            <span class="text-xs text-sr-muted">Trusted</span>
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

    assigns =
      assigns
      |> assign(:score_display, format_risk_score(score))
      |> assign(:max_display, format_risk_score(max_score))
      |> assign(:percent, percent)
      |> assign(:tone_class, risk_score_tone_class(score, max_score))

    ~H"""
    <div
      data-role="risk-score-radial"
      class={["radial-progress shrink-0 text-sm font-semibold tabular-nums", @tone_class]}
      style={"--value:#{@percent}; --size:4.5rem; --thickness:0.4rem;"}
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
      aria-label={"Risk score #{@score_display} out of #{@max_display}"}
    >
      {@score_display}<span class="text-[10px] font-medium text-sr-muted">/{@max_display}</span>
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

  defp risk_score_tone_class(score, max_score) do
    percent = risk_score_percent(score, max_score)

    cond do
      percent >= 70 -> "text-error"
      percent >= 40 -> "text-warning"
      true -> "text-success"
    end
  end

  defp vulnerability_risk_score(assessment_pages) do
    assessment_pages
    |> actionable_assessments()
    |> Enum.map(&vulnerability_finding/1)
    |> ServiceRadar.Inventory.EndpointInventoryVulnerabilityScore.compute()
    |> Map.get(:score)
    |> case do
      score when is_integer(score) and score > 0 -> score
      _ -> nil
    end
  end

  defp actionable_assessments(%{} = pages) do
    pages
    |> Map.get(:confirmed, Map.get(pages, "confirmed", %{}))
    |> case do
      %{rows: rows} -> rows
      %{"rows" => rows} -> rows
      rows when is_list(rows) -> rows
      _ -> []
    end
    |> Enum.filter(&EndpointVulnerabilityAssessment.actionable?/1)
  end

  defp actionable_assessments(assessments) when is_list(assessments) do
    Enum.filter(assessments, &EndpointVulnerabilityAssessment.actionable?/1)
  end

  defp actionable_assessments(_assessment_pages), do: []

  defp vulnerability_risk_level(score) do
    {_id, label} = ServiceRadar.Inventory.DeviceRiskReducer.risk_level_for_score(score)
    label
  end

  defp vulnerability_finding(match) when is_map(match) do
    metadata = Map.get(match, :metadata) || Map.get(match, "metadata") || %{}

    cwes =
      Map.get(match, :cwes) || Map.get(metadata, "cwes") || Map.get(metadata, :cwes) || []

    %{
      cve_id: Map.get(match, :cve_id) || Map.get(match, "cve_id"),
      cvss: Map.get(match, :cvss_score) || Map.get(match, "cvss_score"),
      kev: Map.get(match, :kev) || Map.get(match, "kev"),
      exploit: Map.get(match, :exploit_available) || Map.get(match, "exploit_available"),
      cwes: List.wrap(cwes),
      package: Map.get(match, :package_name) || Map.get(match, "package_name")
    }
  end

  defp vulnerability_finding(_match), do: %{}

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
    label = risk_level_label(assigns.level)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, risk_badge_variant(label))

    ~H"""
    <.ui_badge data-role="risk-level-badge" size="sm" variant={@variant}>{@label}</.ui_badge>
    """
  end

  defp risk_level_label(level) when is_atom(level), do: risk_level_label(Atom.to_string(level))

  defp risk_level_label(level) when is_binary(level) do
    case level |> String.trim() |> String.downcase() do
      "critical" -> "Critical"
      "high" -> "High"
      "medium" -> "Medium"
      "low" -> "Low"
      "info" -> "Info"
      other -> other
    end
  end

  defp risk_level_label(level), do: to_string(level)

  defp risk_badge_variant("Critical"), do: "error"
  defp risk_badge_variant("High"), do: "warning"
  defp risk_badge_variant("Medium"), do: "info"
  defp risk_badge_variant("Low"), do: "success"
  defp risk_badge_variant(_level), do: "ghost"

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
      <span class="text-xs text-sr-muted">{@label}</span>
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
