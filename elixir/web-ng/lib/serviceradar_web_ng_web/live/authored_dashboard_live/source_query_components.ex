defmodule ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueryComponents do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr :form, :any, required: true
  attr :preview, :any, default: nil
  attr :source_queries, :list, default: []
  attr :templates, :list, default: []
  attr :can_manage?, :boolean, default: false
  attr :timezone, :string, default: "Etc/UTC"

  def source_query_workbench(assigns) do
    ~H"""
    <section class="rounded-lg border border-slate-800/80 bg-slate-950/40">
      <div class="flex flex-col gap-2 border-b border-slate-800/80 px-4 py-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <p class="text-xs font-semibold uppercase tracking-normal text-cyan-400">
            Query-first builder
          </p>
          <h3 class="mt-1 text-sm font-semibold text-slate-100">Source query to outputs</h3>
          <p class="text-xs text-slate-400">
            Run SRQL once, inspect returned fields, then add one or more compatible outputs to the dashboard canvas.
          </p>
        </div>
        <.ui_badge size="sm" variant="outline" class="border-slate-700 text-slate-300">
          {length(@source_queries)} sources
        </.ui_badge>
      </div>

      <div class="grid grid-cols-1 gap-4 p-4 xl:grid-cols-[minmax(0,1fr)_360px]">
        <.form
          for={@form}
          as={:source_query}
          phx-change="validate_source_query"
          phx-submit="run_source_query"
          class="space-y-3"
        >
          <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
            <.input field={@form[:name]} type="text" label="Source name" />
            <.input field={@form[:title]} type="text" label="Output title" />
          </div>

          <.srql_editor
            id="dashboard-source-query-editor"
            field={@form[:srql_query]}
            label="SRQL source query"
            rich
          />

          <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
            <.input field={@form[:display_label]} type="text" label="Display label" />
            <.input field={@form[:unit]} type="text" label="Unit" />
            <.input field={@form[:lookback_days]} type="number" label="Lookback days" />
          </div>

          <.input field={@form[:caption]} type="text" label="Caption" />

          <div class="flex flex-wrap items-center gap-2">
            <.ui_button type="submit" disabled={!@can_manage?} size="sm" variant="primary">
              <.icon name="hero-play" class="size-4" /> Run Source Query
            </.ui_button>
            <.ui_button
              :for={template <- @templates}
              type="button"
              phx-click="apply_source_template"
              phx-value-key={template.key}
              disabled={!@can_manage?}
              title={template.description}
              size="sm"
              variant="neutral"
            >
              {template.label}
            </.ui_button>
          </div>
        </.form>

        <div class="space-y-3">
          <div class="rounded-lg border border-slate-800 bg-slate-950/60 p-3">
            <h4 class="text-xs font-semibold uppercase tracking-normal text-slate-400">
              Source schema
            </h4>

            <div :if={!@preview} class="mt-3 text-sm text-slate-500">
              Run a source query to see sample rows, field types, and compatible output intents.
            </div>

            <div :if={@preview} class="mt-3 space-y-3">
              <div class="flex flex-wrap gap-2">
                <.ui_badge size="sm" variant="outline" class="border-slate-700 text-slate-300">
                  {@preview.row_count} rows
                </.ui_badge>
                <.ui_badge size="sm" variant="outline" class="border-slate-700 text-slate-300">
                  {length(@preview.fields)} fields
                </.ui_badge>
              </div>

              <div class="max-h-44 overflow-auto rounded border border-slate-800">
                <table class={ui_table_class(size: "xs")}>
                  <thead>
                    <tr>
                      <th>Field</th>
                      <th>Type</th>
                      <th>Sample</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={field <- @preview.fields} data-source-field={field.name}>
                      <td class="font-mono">{field.name}</td>
                      <td>{field.type}</td>
                      <td class="max-w-36 truncate">
                        <.user_time
                          :if={datetime_field?(field)}
                          id={source_sample_time_id(field.name)}
                          value={field.sample}
                          timezone={@timezone}
                          style={:compact}
                          fallback={format_sample(field.sample)}
                        />
                        <span :if={!datetime_field?(field)}>{format_sample(field.sample)}</span>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <div :if={@preview} class="rounded-lg border border-slate-800 bg-slate-950/60 p-3">
            <h4 class="text-xs font-semibold uppercase tracking-normal text-slate-400">
              Add output
            </h4>
            <div class="mt-3 grid grid-cols-1 gap-2">
              <.ui_button
                :for={output <- @preview.outputs}
                type="button"
                phx-click="create_source_output"
                phx-value-visual-type={output["visual_type"]}
                disabled={!@can_manage?}
                title={output["description"]}
                size="sm"
                variant="neutral"
                class="h-auto min-h-12 justify-start py-2"
              >
                <.icon name="hero-plus" class="size-4 shrink-0" />
                <span class="flex min-w-0 flex-col items-start text-left leading-tight">
                  <span>{output["label"]}</span>
                  <span
                    :if={output["summary"]}
                    class="mt-1 truncate text-[11px] font-normal opacity-70"
                  >
                    {output["summary"]}
                  </span>
                </span>
              </.ui_button>
            </div>
          </div>

          <div
            :if={@source_queries != []}
            class="rounded-lg border border-slate-800 bg-slate-950/60 p-3"
          >
            <h4 class="text-xs font-semibold uppercase tracking-normal text-slate-400">
              Reusable sources
            </h4>
            <div class="mt-3 space-y-2">
              <div :for={source <- @source_queries} class="rounded border border-slate-800 p-2">
                <div class="flex items-start justify-between gap-2">
                  <div class="min-w-0">
                    <div class="truncate text-sm font-semibold text-slate-100">{source.name}</div>
                    <div class="mt-1 text-[11px] text-slate-500">
                      {source.panel_count} linked {if source.panel_count == 1,
                        do: "panel",
                        else: "panels"}
                    </div>
                  </div>
                  <div class="flex shrink-0 items-center gap-1">
                    <.ui_button
                      type="button"
                      phx-click="load_source_query"
                      phx-value-id={source.id}
                      disabled={!@can_manage?}
                      size="xs"
                      variant="neutral"
                    >
                      Load
                    </.ui_button>
                    <.ui_button
                      type="button"
                      phx-click="remove_source_query"
                      phx-value-id={source.id}
                      disabled={!@can_manage? or source.panel_count > 0}
                      title={
                        if source.panel_count > 0,
                          do: "Remove linked panels before deleting this source",
                          else: "Remove source"
                      }
                      size="xs"
                      variant="outline"
                    >
                      Remove
                    </.ui_button>
                  </div>
                </div>
                <div class="mt-1 truncate font-mono text-[11px] text-cyan-300">
                  {source.srql_query}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp format_sample(value) when is_binary(value), do: value
  defp format_sample(value) when is_number(value), do: to_string(value)
  defp format_sample(value) when is_boolean(value), do: to_string(value)
  defp format_sample(nil), do: ""
  defp format_sample(value), do: inspect(value)

  defp datetime_field?(%{type: type}), do: type in [:datetime, "datetime"]
  defp datetime_field?(%{"type" => type}), do: type in [:datetime, "datetime"]
  defp datetime_field?(_field), do: false

  defp source_sample_time_id(field_name) do
    encoded_name = field_name |> to_string() |> Base.url_encode64(padding: false)
    "authored-dashboard-source-field-#{encoded_name}-sample"
  end
end
