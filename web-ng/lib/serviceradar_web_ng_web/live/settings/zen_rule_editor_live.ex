defmodule ServiceRadarWebNGWeb.Settings.ZenRuleEditorLive do
  @moduledoc """
  LiveView for editing Zen rules with the GoRules JDM visual editor.

  This provides a first-class editing experience for Zen rules, allowing users
  to visually build decision logic or edit the raw JSON. The editor supports:

  - Visual canvas editing via the JDM editor
  - JSON view for advanced users
  - Create, edit, and clone flows
  - Real-time validation and preview
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.SettingsComponents

  alias ServiceRadar.Observability.ZenRule

  require Ash.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case find_rule(scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Rule not found")
         |> redirect(to: ~p"/settings/rules?tab=logs")}

      rule ->
        {:ok, init_editor(socket, scope, rule, :edit)}
    end
  end

  def mount(%{"clone_id" => clone_id}, _session, socket) do
    scope = socket.assigns.current_scope

    case find_rule(scope, clone_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Rule not found")
         |> redirect(to: ~p"/settings/rules?tab=logs")}

      rule ->
        # Clone the rule (new record with copied values)
        cloned = %{rule | id: nil, name: "#{rule.name} (copy)"}
        {:ok, init_editor(socket, scope, cloned, :create)}
    end
  end

  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    {:ok, init_editor(socket, scope, nil, :create)}
  end

  defp init_editor(socket, scope, rule, mode) do
    # Get or create jdm_definition
    jdm_definition =
      if rule && rule.jdm_definition && map_size(rule.jdm_definition) > 0 do
        rule.jdm_definition
      else
        default_jdm_definition()
      end

    ash_form = build_form(scope, rule, mode)

    socket
    |> assign(:page_title, page_title(mode, rule))
    |> assign(:mode, mode)
    |> assign(:rule, rule)
    |> assign(:jdm_definition, jdm_definition)
    |> assign(:ash_form, ash_form)
    |> assign(:form, to_form(ash_form))
    |> assign(:dirty, false)
    |> assign(:saving, false)
  end

  defp page_title(:create, _), do: "Create Zen Rule"
  defp page_title(:edit, rule), do: "Edit: #{rule.name}"

  @impl true
  def handle_event("validate", %{"zen_rule" => params}, socket) do
    ash_form =
      socket.assigns.ash_form
      |> AshPhoenix.Form.validate(params)

    {:noreply,
     socket
     |> assign(:ash_form, ash_form)
     |> assign(:form, to_form(ash_form))
     |> assign(:dirty, true)}
  end

  def handle_event("save", %{"zen_rule" => params}, socket) do
    # Include the jdm_definition in the params
    params = Map.put(params, "jdm_definition", socket.assigns.jdm_definition)

    case AshPhoenix.Form.submit(socket.assigns.ash_form, params: params) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rule saved successfully")
         |> assign(:dirty, false)
         |> assign(:rule, rule)
         |> assign(:mode, :edit)
         |> push_patch(to: ~p"/settings/rules/zen/#{rule.id}")}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))
         |> put_flash(:error, "Failed to save rule. Check the form for errors.")}
    end
  end

  def handle_event("jdm_editor_change", %{"definition" => definition}, socket) do
    {:noreply,
     socket
     |> assign(:jdm_definition, definition)
     |> assign(:dirty, true)}
  end

  def handle_event("jdm_editor_save", %{"definition" => definition}, socket) do
    # Save the rule with the new definition
    params = %{
      "jdm_definition" => definition
    }

    ash_form =
      socket.assigns.ash_form
      |> AshPhoenix.Form.validate(params)

    case AshPhoenix.Form.submit(ash_form, params: params) do
      {:ok, rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rule saved successfully")
         |> assign(:jdm_definition, definition)
         |> assign(:dirty, false)
         |> assign(:rule, rule)}

      {:error, ash_form} ->
        {:noreply,
         socket
         |> assign(:ash_form, ash_form)
         |> assign(:form, to_form(ash_form))
         |> put_flash(:error, "Failed to save rule")}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, redirect(socket, to: ~p"/settings/rules?tab=logs")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.settings_shell current_path="/settings/rules">
        <.settings_nav current_path="/settings/rules" />

        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">{@page_title}</h1>
            <p class="text-sm text-base-content/60">
              Build decision logic for log normalization using the visual editor or JSON.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <.ui_button variant="ghost" phx-click="cancel">
              Cancel
            </.ui_button>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-[320px_1fr] gap-6">
          <!-- Rule Properties Panel -->
          <div class="space-y-4">
            <.ui_panel>
              <:header>
                <div class="text-sm font-semibold">Rule Properties</div>
              </:header>

              <.form
                for={@form}
                id="zen_rule_form"
                class="space-y-3"
                phx-change="validate"
                phx-submit="save"
              >
                <.input field={@form[:name]} label="Rule ID" placeholder="my-rule-name" />
                <.input field={@form[:description]} label="Description" type="textarea" rows="2" />
                <.input
                  field={@form[:subject]}
                  label="Subject"
                  type="text"
                  placeholder="logs.syslog"
                  list="zen-subjects"
                />
                <datalist id="zen-subjects">
                  <option value="logs.syslog" />
                  <option value="logs.snmp" />
                  <option value="logs.otel" />
                  <option value="otel.metrics.raw" />
                  <option value="logs.internal.health" />
                  <option value="logs.internal.jobs" />
                </datalist>
                <.input field={@form[:order]} label="Priority order" type="number" />
                <.input field={@form[:enabled]} label="Enabled" type="checkbox" />
                <.input field={@form[:stream_name]} type="hidden" value="events" />
                <.input field={@form[:agent_id]} type="hidden" value="default-agent" />
                <.input field={@form[:template]} type="hidden" value="passthrough" />

                <div class="pt-2">
                  <.button variant="primary" class="w-full" phx-disable-with="Saving...">
                    <.icon name="hero-check" class="w-4 h-4 mr-2" />
                    Save Rule
                  </.button>
                </div>
              </.form>
            </.ui_panel>

            <.ui_panel :if={@dirty}>
              <div class="flex items-center gap-2 text-warning">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                <span class="text-sm">Unsaved changes</span>
              </div>
            </.ui_panel>
          </div>

          <!-- JDM Editor Panel -->
          <.ui_panel class="min-h-[600px]">
            <:header>
              <div class="text-sm font-semibold">Decision Logic</div>
              <div class="text-xs text-base-content/60">
                Build your rule logic using the visual editor or switch to JSON view.
              </div>
            </:header>

            <div class="h-[calc(100vh-400px)] min-h-[500px]">
              <.jdm_editor
                id="zen-rule-jdm-editor"
                definition={@jdm_definition}
                read_only={false}
              />
            </div>
          </.ui_panel>
        </div>
      </.settings_shell>
    </Layouts.app>
    """
  end

  defp build_form(scope, rule, mode) do
    opts = [
      domain: ServiceRadar.Observability,
      scope: scope,
      as: "zen_rule",
      transform_params: &normalize_params/3
    ]

    case mode do
      :create ->
        AshPhoenix.Form.for_create(ZenRule, :create, opts)

      :edit ->
        AshPhoenix.Form.for_update(rule, :update, opts)
    end
  end

  defp normalize_params(_form, params, _action) do
    params
    |> normalize_integer("order")
  end

  defp normalize_integer(params, key) do
    case Map.get(params, key) do
      "" -> Map.delete(params, key)
      nil -> params
      value when is_integer(value) -> params
      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> Map.put(params, key, int)
          :error -> params
        end
      _ -> params
    end
  end

  defp find_rule(scope, id) do
    ZenRule
    |> Ash.Query.for_read(:read, %{})
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(scope: scope)
    |> case do
      {:ok, rule} -> rule
      _ -> nil
    end
  end

  defp default_jdm_definition do
    %{
      "nodes" => [
        %{
          "id" => "input",
          "type" => "inputNode",
          "position" => %{"x" => 100, "y" => 200},
          "name" => "Input"
        },
        %{
          "id" => "output",
          "type" => "outputNode",
          "position" => %{"x" => 600, "y" => 200},
          "name" => "Output"
        }
      ],
      "edges" => []
    }
  end
end
