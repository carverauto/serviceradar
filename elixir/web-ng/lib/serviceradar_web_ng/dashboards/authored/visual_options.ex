defmodule ServiceRadarWebNG.Dashboards.Authored.VisualOptions do
  @moduledoc false

  @visuals [
    %{
      type: :table,
      label: "Table",
      description: "Rows and columns for any SRQL result."
    },
    %{
      type: :stat,
      label: "Stat",
      description: "Single numeric value with an optional label."
    },
    %{
      type: :count,
      label: "Count",
      description: "Current count with optional trend-over-time comparison."
    },
    %{
      type: :gauge,
      label: "Gauge",
      description: "Bounded value with thresholds, units, and a prominent label."
    },
    %{
      type: :availability,
      label: "Availability",
      description: "Availability ratio from explicit numerator and denominator bindings."
    },
    %{
      type: :line,
      label: "Line",
      description: "Time series trend with a timestamp and numeric value."
    },
    %{
      type: :area,
      label: "Area",
      description: "Filled time series trend with a timestamp and numeric value."
    },
    %{
      type: :bar,
      label: "Bar",
      description: "Categorical or ranked numeric comparison."
    },
    %{
      type: :category,
      label: "Category",
      description: "Breakdown by string labels and numeric values."
    },
    %{
      type: :status_list,
      label: "Status List",
      description: "Operational rows with status or health fields."
    },
    %{
      type: :pivot,
      label: "Pivot Table",
      description: "Cross-tab analysis from row, column, and aggregate bindings."
    }
  ]

  @spec all() :: [map()]
  def all, do: @visuals

  @spec types() :: [atom()]
  def types do
    Enum.map(@visuals, & &1.type)
  end
end
