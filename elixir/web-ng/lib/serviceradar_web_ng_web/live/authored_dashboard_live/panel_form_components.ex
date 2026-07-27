defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.PanelFormComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  attr(:form, :any, required: true)
  attr(:panel, :any, default: nil)
  attr(:preview, :any, default: nil)
  attr(:panel_results, :map, default: %{})

  def panel_form_fields(assigns) do
    assigns =
      assigns
      |> assign(:field_options, panel_field_options(assigns.preview, assigns.panel, assigns.panel_results))
      |> assign(
        :numeric_field_options,
        numeric_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(
        :dimension_field_options,
        dimension_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(
        :datetime_field_options,
        datetime_panel_field_options(assigns.preview, assigns.panel, assigns.panel_results)
      )
      |> assign(:visual_options, panel_visual_select_options(assigns.preview, assigns.panel))
      |> assign(:visual_locked?, is_nil(assigns.preview) and is_nil(assigns.panel))

    ~H"""
    <section class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4">
      <div>
        <p class="text-xs font-semibold uppercase tracking-normal text-sr-brand">Step 1</p>
        <h3 class="mt-1 text-sm font-semibold">SRQL source</h3>
        <p class="text-xs text-sr-muted">
          Define the dataset query this panel owns. Previewing the query drives the available visuals and field bindings.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3">
        <.input field={@form[:title]} type="text" label="Panel title" />
      </div>

      <.srql_editor
        id={"authored-panel-srql-editor-#{(@panel && @panel.id) || "new"}"}
        field={@form[:srql_query]}
        label="SRQL Query"
        rich
      />

      <div class="flex flex-wrap items-center gap-2">
        <.ui_button type="submit" name="intent" value="preview" size="sm" variant="neutral">
          <.icon name="hero-play" class="size-4" /> Preview Query
        </.ui_button>
        <span :if={!@preview and is_nil(@panel)} class="text-xs text-sr-muted">
          Preview first to unlock compatible visualizations.
        </span>
      </div>
    </section>

    <section class="space-y-4 rounded-lg border border-sr-line bg-sr-surface p-4">
      <div>
        <p class="text-xs font-semibold uppercase tracking-normal text-sr-brand">Step 2</p>
        <h3 class="mt-1 text-sm font-semibold">Visualization and bindings</h3>
        <p class="text-xs text-sr-muted">
          Choose a supported visual and map fields from the preview output into labels, values, status, and layout.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.input
          field={@form[:visual_type]}
          type="select"
          label="Visualization"
          options={@visual_options}
          disabled={@visual_locked?}
        />
        <.input
          field={@form[:refresh_interval_seconds]}
          type="number"
          label="Refresh interval seconds"
        />
        <.input field={@form[:position]} type="number" label="Position" />
      </div>

      <.panel_structured_fields
        form={@form}
        field_options={@field_options}
        numeric_field_options={@numeric_field_options}
        dimension_field_options={@dimension_field_options}
        datetime_field_options={@datetime_field_options}
        locked?={@visual_locked?}
      />

      <div class="flex flex-wrap gap-2 border-t border-sr-line pt-4">
        <.ui_button
          type="submit"
          name="intent"
          value="save"
          disabled={!@preview and is_nil(@panel)}
          size="sm"
          variant="primary"
        >
          <.icon name="hero-check" class="size-4" /> Save Panel
        </.ui_button>
        <.ui_button type="button" phx-click="cancel_panel_edit" size="sm" variant="neutral">
          Cancel
        </.ui_button>
      </div>
    </section>
    """
  end

  attr(:form, :any, required: true)
  attr(:field_options, :list, default: [])
  attr(:numeric_field_options, :list, default: [])
  attr(:dimension_field_options, :list, default: [])
  attr(:datetime_field_options, :list, default: [])
  attr(:locked?, :boolean, default: false)

  defp panel_structured_fields(assigns) do
    visual = assigns.form |> Phoenix.HTML.Form.input_value(:visual_type) |> to_string()

    assigns =
      assigns
      |> assign(:visual, visual)
      |> assign(:grouped_availability?, grouped_availability_options?(visual, assigns))
      |> assign(:aggregate_options, [
        {"Sum", "sum"},
        {"Average", "avg"},
        {"Minimum", "min"},
        {"Maximum", "max"},
        {"Count", "count"}
      ])

    ~H"""
    <section
      :if={@locked?}
      class="rounded-lg border border-dashed border-sr-line bg-sr-surface p-4 text-sm text-sr-muted lg:col-span-2"
    >
      <div class="font-medium text-sr-ink">Preview the SRQL query first</div>
      <p class="mt-1 text-xs">
        The builder will inspect the returned fields and then unlock only the visualization and binding controls that fit this query.
      </p>
    </section>

    <section
      :if={!@locked?}
      class="grid grid-cols-1 gap-3 rounded-lg border border-sr-line bg-sr-surface p-3 lg:col-span-2 lg:grid-cols-2"
    >
      <div class="lg:col-span-2">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
          Data bindings
        </h4>
      </div>
      <.input
        :if={
          @visual in ["stat", "count", "gauge", "line", "area", "bar", "category", "pivot"] or
            @grouped_availability?
        }
        field={@form[:value_field]}
        type="select"
        label={if @grouped_availability?, do: "Count field", else: "Value field"}
        options={@numeric_field_options}
      />
      <.input
        :if={@visual == "availability" and !@grouped_availability?}
        field={@form[:numerator_field]}
        type="select"
        label="Available/OK field"
        options={@numeric_field_options}
      />
      <.input
        :if={@visual == "availability" and !@grouped_availability?}
        field={@form[:denominator_field]}
        type="select"
        label="Total field"
        options={@numeric_field_options}
      />
      <.input
        :if={
          @visual in [
            "stat",
            "count",
            "gauge",
            "availability",
            "line",
            "area",
            "bar",
            "category",
            "status_list"
          ]
        }
        field={@form[:label_field]}
        type="select"
        label={if @grouped_availability?, do: "Availability field", else: "Label field"}
        options={@field_options}
      />
      <.input
        :if={@visual in ["line", "area"]}
        field={@form[:time_field]}
        type="select"
        label="Time field"
        options={@datetime_field_options}
      />
      <.input
        :if={@visual in ["line", "area"]}
        field={@form[:capacity_forecast_mode]}
        type="select"
        label="Forecast overlay"
        options={[
          {"Standard trend", ""},
          {"Capacity forecast", "capacity_forecast"}
        ]}
      />
      <.input
        :if={@visual == "status_list"}
        field={@form[:status_field]}
        type="select"
        label="Status field"
        options={@field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:row_field]}
        type="select"
        label="Rows"
        options={@dimension_field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:column_field]}
        type="select"
        label="Columns"
        options={@dimension_field_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:aggregate]}
        type="select"
        label="Aggregate"
        options={@aggregate_options}
      />
      <.input
        :if={@visual == "pivot"}
        field={@form[:empty_value]}
        type="text"
        label="Empty value"
      />
    </section>

    <section
      :if={!@locked? and @visual in ["stat", "count", "gauge", "availability"]}
      class="grid grid-cols-1 gap-3 rounded-lg border border-sr-line bg-sr-surface p-3 lg:col-span-2 lg:grid-cols-2"
    >
      <div class="lg:col-span-2">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
          Trend comparison
        </h4>
        <p class="mt-1 text-xs text-sr-muted">
          Compare this metric with a prior SRQL result, such as a bucketed or stats query for the previous period.
        </p>
      </div>
      <.input
        field={@form[:trend_mode]}
        type="select"
        label="Trend"
        options={[
          {"Off", ""},
          {"Compare with prior period", "compare_previous"},
          {"Custom SRQL comparison", "custom_query"}
        ]}
      />
      <.input field={@form[:trend_lookback_days]} type="number" label="Lookback days" />
      <div class="lg:col-span-2">
        <.input
          field={@form[:trend_query]}
          type="textarea"
          label="Trend SRQL"
        />
      </div>
    </section>

    <section
      :if={!@locked?}
      class="grid grid-cols-1 gap-3 rounded-lg border border-sr-line bg-sr-surface p-3 lg:col-span-2 lg:grid-cols-2"
    >
      <div class="lg:col-span-2">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
          Display
        </h4>
      </div>
      <.input field={@form[:display_label]} type="text" label="Display label" />
      <.input field={@form[:unit]} type="text" label="Unit" />
      <.input field={@form[:caption]} type="text" label="Caption" />
      <.input
        :if={@visual == "table"}
        field={@form[:table_columns]}
        type="text"
        label="Table columns"
      />
    </section>

    <section
      :if={!@locked?}
      class="grid grid-cols-2 gap-3 rounded-lg border border-sr-line bg-sr-surface p-3 lg:col-span-2 lg:grid-cols-4"
    >
      <div class="col-span-2 lg:col-span-4">
        <h4 class="text-xs font-semibold uppercase tracking-normal text-sr-muted">
          Layout
        </h4>
      </div>
      <.input field={@form[:layout_x]} type="number" label="X" />
      <.input field={@form[:layout_y]} type="number" label="Y" />
      <.input field={@form[:layout_w]} type="number" label="Width" />
      <.input field={@form[:layout_h]} type="number" label="Height" />
    </section>
    """
  end

  defp panel_field_options(preview, panel, panel_results) do
    fields = panel_fields(preview, panel, panel_results)
    SourceQueries.field_options(fields)
  end

  defp numeric_panel_field_options(preview, panel, panel_results) do
    fields = panel_fields(preview, panel, panel_results)
    SourceQueries.numeric_field_options(fields)
  end

  defp dimension_panel_field_options(preview, panel, panel_results) do
    fields = panel_fields(preview, panel, panel_results)
    SourceQueries.dimension_field_options(fields)
  end

  defp datetime_panel_field_options(preview, panel, panel_results) do
    fields = panel_fields(preview, panel, panel_results)
    SourceQueries.datetime_field_options(fields)
  end

  defp panel_visual_select_options(nil, nil), do: [{"Preview query first", ""}]

  defp panel_visual_select_options(preview, panel) do
    SourceQueries.compatible_visual_options(preview, panel)
  end

  defp grouped_availability_options?("availability", assigns) do
    option_value?(assigns.numeric_field_options, "count") and
      Enum.any?(["is_available", "available", "availability"], &option_value?(assigns.field_options, &1))
  end

  defp grouped_availability_options?(_visual, _assigns), do: false

  defp option_value?(options, value) do
    Enum.any?(options, fn
      {_label, ^value} -> true
      %{value: ^value} -> true
      option when is_binary(option) -> option == value
      _option -> false
    end)
  end

  defp panel_fields(preview, panel, panel_results) do
    cond do
      SourceQueries.preview_fields(preview) != [] ->
        SourceQueries.preview_fields(preview)

      panel && match?({:ok, _}, Map.get(panel_results, panel.id)) ->
        {:ok, result} = Map.get(panel_results, panel.id)
        SourceQueries.preview_fields(result)

      panel ->
        SourceQueries.metadata_fields(panel.field_metadata || %{})

      true ->
        []
    end
  end
end
