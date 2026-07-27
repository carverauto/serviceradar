defmodule ServiceRadarWebNGWeb.Settings.DeviceEnrichmentRulesLive do
  @moduledoc """
  Structured editor for filesystem-backed device enrichment rules.
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Events.AuditWriter
  alias ServiceRadar.Inventory.DeviceEnrichmentRules
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @default_rules_dir "/var/lib/serviceradar/rules/device-enrichment"
  @match_keys ~w(sys_descr sys_name hostname source sys_object_id_prefixes ip_forwarding)
  @set_keys ~w(vendor_name model type type_id model_from_sys_descr_prefix)
  @match_field_defs [
    {"sys_descr", :all_sys_descr, :any_sys_descr},
    {"sys_name", :all_sys_name, :any_sys_name},
    {"hostname", :all_hostname, :any_hostname},
    {"source", :all_source, :any_source},
    {"sys_object_id_prefixes", :all_sys_object_id_prefixes, :any_sys_object_id_prefixes},
    {"ip_forwarding", :all_ip_forwarding, :any_ip_forwarding}
  ]
  @set_field_defs [
    {"vendor_name", :set_vendor_name},
    {"model", :set_model},
    {"type", :set_type},
    {"type_id", :set_type_id},
    {"model_from_sys_descr_prefix", :set_model_from_sys_descr_prefix}
  ]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if can_manage?(scope) do
      rules_dir = rules_dir()
      files = list_rule_files(rules_dir)

      socket =
        socket
        |> assign(:page_title, "Device Enrichment Rules")
        |> assign(:current_path, "/settings/networks/device-enrichment")
        |> assign(:rules_dir, rules_dir)
        |> assign(:rule_files, files)
        |> assign(:selected_file, nil)
        |> assign(:selected_file_source, nil)
        |> assign(:selected_file_state, nil)
        |> assign(:selected_file_mtime, nil)
        |> assign(:rules, [])
        |> assign(:show_new_file_modal, false)
        |> assign(:show_import_modal, false)
        |> assign(:show_export_modal, false)
        |> assign(:export_yaml, "")
        |> assign(:show_rule_editor, false)
        |> assign(:show_discard_rule_modal, false)
        |> assign(:editing_index, nil)
        |> assign(:rule_form_dirty, false)
        |> assign(
          :simulation_form,
          to_form(%{"payload" => default_simulation_payload()}, as: :simulation)
        )
        |> assign(:simulation_result, nil)
        |> assign(:new_file_form, to_form(%{"file_name" => ""}, as: :new_file))
        |> assign(:import_form, to_form(%{"yaml" => ""}, as: :import))
        |> assign(:rule_form, to_form(default_rule_form(), as: :rule))

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage device enrichment rules")
       |> push_navigate(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_event("open_new_file", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_file_modal, true)
     |> assign(:new_file_form, to_form(%{"file_name" => ""}, as: :new_file))}
  end

  def handle_event("cancel_new_file", _params, socket) do
    {:noreply, assign(socket, :show_new_file_modal, false)}
  end

  def handle_event("create_file", %{"new_file" => %{"file_name" => file_name}}, socket) do
    with {:ok, normalized_name} <- normalize_file_name(file_name),
         false <- File.exists?(Path.join(socket.assigns.rules_dir, normalized_name)),
         :ok <- write_rules_file(socket.assigns.rules_dir, normalized_name, []) do
      record_rules_audit(socket, :create_file, normalized_name, %{
        rules: rules_change_summary([], []),
        status: "success"
      })

      {:noreply,
       socket
       |> assign(:rule_files, list_rule_files(socket.assigns.rules_dir))
       |> assign(:show_new_file_modal, false)
       |> put_flash(:info, "Created #{normalized_name}")
       |> load_selected_file(normalized_name)}
    else
      true ->
        {:noreply, put_flash(socket, :error, "File already exists")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("select_file", %{"file" => file}, socket) do
    {:noreply, load_selected_file(socket, file)}
  end

  def handle_event("deactivate_file", %{"file" => file}, socket) do
    with {:ok, normalized_file} <- normalize_file_name(file),
         :ok <- deactivate_override_file(socket.assigns.rules_dir, normalized_file) do
      record_rules_audit(socket, :deactivate_file, normalized_file, %{status: "success"})

      socket =
        socket
        |> assign(:rule_files, list_rule_files(socket.assigns.rules_dir))
        |> put_flash(:info, "Deactivated #{normalized_file}")

      {:noreply,
       if socket.assigns.selected_file == normalized_file do
         load_selected_file(socket, normalized_file)
       else
         socket
       end}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("activate_file", %{"file" => file}, socket) do
    with {:ok, normalized_file} <- normalize_file_name(file),
         :ok <- activate_override_file(socket.assigns.rules_dir, normalized_file) do
      record_rules_audit(socket, :activate_file, normalized_file, %{status: "success"})

      socket =
        socket
        |> assign(:rule_files, list_rule_files(socket.assigns.rules_dir))
        |> put_flash(:info, "Activated #{normalized_file}")

      {:noreply,
       if socket.assigns.selected_file == normalized_file do
         load_selected_file(socket, normalized_file)
       else
         socket
       end}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("delete_file", %{"file" => file}, socket) do
    with {:ok, normalized_file} <- normalize_file_name(file),
         :ok <- delete_override_file(socket.assigns.rules_dir, normalized_file) do
      record_rules_audit(socket, :delete_file, normalized_file, %{status: "success"})

      socket =
        socket
        |> assign(:rule_files, list_rule_files(socket.assigns.rules_dir))
        |> put_flash(:info, "Deleted #{normalized_file}")

      {:noreply,
       if socket.assigns.selected_file == normalized_file do
         socket
         |> assign(:selected_file, nil)
         |> assign(:selected_file_source, nil)
         |> assign(:selected_file_state, nil)
         |> assign(:selected_file_mtime, nil)
         |> assign(:rules, [])
       else
         socket
       end}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("reload_file", _params, socket) do
    case socket.assigns.selected_file do
      nil -> {:noreply, socket}
      file -> {:noreply, load_selected_file(socket, file)}
    end
  end

  def handle_event("open_import_yaml", _params, socket) do
    if is_nil(socket.assigns.selected_file) do
      {:noreply, put_flash(socket, :error, "Select a rule file first")}
    else
      case ensure_selected_editable(socket) do
        :ok ->
          {:noreply,
           socket
           |> assign(:show_import_modal, true)
           |> assign(:import_form, to_form(%{"yaml" => ""}, as: :import))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  def handle_event("cancel_import_yaml", _params, socket) do
    {:noreply, assign(socket, :show_import_modal, false)}
  end

  def handle_event("import_yaml", %{"import" => %{"yaml" => yaml}}, socket) do
    file_name = socket.assigns.selected_file
    before_rules = socket.assigns.rules

    with :ok <- ensure_selected_editable(socket),
         true <- is_binary(file_name),
         {:ok, _} <- DeviceEnrichmentRules.parse_and_validate_yaml(yaml, file: file_name),
         {:ok, imported_rules} <- parse_file_rules(yaml, file_name),
         :ok <-
           write_rules_file(
             socket.assigns.rules_dir,
             file_name,
             imported_rules,
             socket.assigns.selected_file_mtime
           ) do
      record_rules_audit(socket, :import_yaml, file_name, %{
        rules: rules_change_summary(before_rules, imported_rules),
        status: "success"
      })

      {:noreply,
       socket
       |> assign(:show_import_modal, false)
       |> assign(:rules, imported_rules)
       |> load_selected_file(file_name)
       |> put_flash(:info, "Imported YAML into #{file_name}")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Select a rule file first")}

      {:error, errors} when is_list(errors) ->
        {:noreply, put_flash(socket, :error, Enum.join(errors, "; "))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("open_export_yaml", _params, socket) do
    case socket.assigns.selected_file do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a rule file first")}

      file_name ->
        case read_rule_file(socket.assigns.rules_dir, file_name) do
          {:ok, content, _source, _state} ->
            {:noreply,
             socket
             |> assign(:show_export_modal, true)
             |> assign(:export_yaml, content)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to read #{file_name}: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("close_export_yaml", _params, socket) do
    {:noreply, assign(socket, :show_export_modal, false)}
  end

  def handle_event("download_export_yaml", _params, socket) do
    file_name = socket.assigns.selected_file || "device-enrichment-rules.yaml"
    yaml = socket.assigns.export_yaml || ""

    if String.trim(yaml) == "" do
      {:noreply, put_flash(socket, :error, "Nothing to download yet")}
    else
      record_rules_audit(socket, :export_yaml, file_name, %{
        status: "success",
        bytes: byte_size(yaml)
      })

      {:noreply,
       socket
       |> push_event("download_yaml", %{filename: file_name, content: yaml})
       |> put_flash(:info, "Downloading #{file_name}")}
    end
  end

  def handle_event("new_rule", _params, socket) do
    if is_nil(socket.assigns.selected_file) do
      {:noreply, put_flash(socket, :error, "Create or select a rule file first")}
    else
      case ensure_selected_editable(socket) do
        :ok ->
          {:noreply,
           socket
           |> assign(:show_rule_editor, true)
           |> assign(:show_discard_rule_modal, false)
           |> assign(:editing_index, nil)
           |> assign(:rule_form_dirty, false)
           |> assign(:rule_form, to_form(default_rule_form(), as: :rule))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, reason)}
      end
    end
  end

  def handle_event("edit_rule", %{"index" => index}, socket) do
    idx = parse_index(index)

    case Enum.at(socket.assigns.rules, idx) do
      nil ->
        {:noreply, put_flash(socket, :error, "Rule not found")}

      rule ->
        {:noreply,
         socket
         |> assign(:show_rule_editor, true)
         |> assign(:show_discard_rule_modal, false)
         |> assign(:editing_index, idx)
         |> assign(:rule_form_dirty, false)
         |> assign(:rule_form, to_form(rule_to_form(rule), as: :rule))}
    end
  end

  def handle_event("rule_form_changed", %{"rule" => params}, socket) do
    {:noreply,
     socket
     |> assign(:rule_form, to_form(params, as: :rule))
     |> assign(:rule_form_dirty, true)}
  end

  def handle_event("cancel_rule", _params, socket) do
    close_rule_editor(socket)
  end

  def handle_event("attempt_close_rule_editor", _params, socket) do
    close_rule_editor(socket)
  end

  def handle_event("rule_editor_escape", _params, socket) do
    if socket.assigns.show_discard_rule_modal do
      {:noreply, assign(socket, :show_discard_rule_modal, false)}
    else
      close_rule_editor(socket)
    end
  end

  def handle_event("keep_editing_rule", _params, socket) do
    {:noreply, assign(socket, :show_discard_rule_modal, false)}
  end

  def handle_event("discard_rule_changes", _params, socket) do
    {:noreply, reset_rule_editor(socket)}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    before_rules = socket.assigns.rules

    with :ok <- ensure_selected_editable(socket),
         {:ok, rule} <- form_to_rule(params),
         {:ok, updated_rules} <-
           upsert_rule(socket.assigns.rules, socket.assigns.editing_index, rule),
         {:ok, validated_rules} <- validate_rules(updated_rules, socket.assigns.selected_file),
         :ok <-
           write_rules_file(
             socket.assigns.rules_dir,
             socket.assigns.selected_file,
             validated_rules,
             socket.assigns.selected_file_mtime
           ) do
      record_rules_audit(socket, :save_rule, socket.assigns.selected_file, %{
        rule_id: Map.get(rule, "id"),
        editing_index: socket.assigns.editing_index,
        rules: rules_change_summary(before_rules, validated_rules),
        status: "success"
      })

      {:noreply,
       socket
       |> assign(:rules, validated_rules)
       |> load_selected_file(socket.assigns.selected_file)
       |> reset_rule_editor()
       |> put_flash(:info, "Rule saved. Restart or reload core to apply changes.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("delete_rule", %{"index" => index}, socket) do
    idx = parse_index(index)
    before_rules = socket.assigns.rules

    case remove_rule_at(socket.assigns.rules, idx) do
      {:ok, updated_rules} ->
        with {:ok, validated_rules} <- validate_rules(updated_rules, socket.assigns.selected_file),
             :ok <-
               write_rules_file(
                 socket.assigns.rules_dir,
                 socket.assigns.selected_file,
                 validated_rules,
                 socket.assigns.selected_file_mtime
               ) do
          record_rules_audit(socket, :delete_rule, socket.assigns.selected_file, %{
            deleted_index: idx,
            rules: rules_change_summary(before_rules, validated_rules),
            status: "success"
          })

          {:noreply,
           socket
           |> assign(:rules, validated_rules)
           |> load_selected_file(socket.assigns.selected_file)
           |> put_flash(:info, "Rule deleted. Restart or reload core to apply changes.")}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("duplicate_rule", %{"index" => index}, socket) do
    idx = parse_index(index)
    before_rules = socket.assigns.rules

    case Enum.at(socket.assigns.rules, idx) do
      nil ->
        {:noreply, put_flash(socket, :error, "Rule not found")}

      rule ->
        duplicated = duplicate_rule(rule, socket.assigns.rules)

        with {:ok, validated_rules} <-
               validate_rules(socket.assigns.rules ++ [duplicated], socket.assigns.selected_file),
             :ok <-
               write_rules_file(
                 socket.assigns.rules_dir,
                 socket.assigns.selected_file,
                 validated_rules,
                 socket.assigns.selected_file_mtime
               ) do
          record_rules_audit(socket, :duplicate_rule, socket.assigns.selected_file, %{
            source_index: idx,
            duplicated_rule_id: Map.get(duplicated, "id"),
            rules: rules_change_summary(before_rules, validated_rules),
            status: "success"
          })

          {:noreply,
           socket
           |> assign(:rules, validated_rules)
           |> load_selected_file(socket.assigns.selected_file)
           |> put_flash(:info, "Rule duplicated")}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  def handle_event("move_rule_up", %{"index" => index}, socket) do
    move_rule(socket, parse_index(index), -1)
  end

  def handle_event("move_rule_down", %{"index" => index}, socket) do
    move_rule(socket, parse_index(index), 1)
  end

  def handle_event("simulate", %{"simulation" => %{"payload" => payload}}, socket) do
    with {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded),
         update = normalize_simulation_update(decoded),
         :ok <- DeviceEnrichmentRules.reload() do
      classification = DeviceEnrichmentRules.classify(update)

      {:noreply,
       socket
       |> assign(:simulation_form, to_form(%{"payload" => payload}, as: :simulation))
       |> assign(:simulation_result, %{update: update, classification: classification})}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid JSON payload: #{inspect(reason)}")}

      false ->
        {:noreply, put_flash(socket, :error, "Simulation payload must be a JSON object")}
    end
  end

  def handle_event("apply_now", _params, socket) do
    case apply_rules_now() do
      {:ok, nodes} ->
        record_rules_audit(socket, :apply_now, socket.assigns.selected_file || "all", %{
          status: "success",
          nodes: Enum.map(nodes, &to_string/1)
        })

        {:noreply,
         put_flash(
           socket,
           :info,
           "Applied rules on #{length(nodes)} core node(s): #{Enum.map_join(nodes, ", ", &to_string/1)}"
         )}

      {:error, :no_coordinator} ->
        record_rules_audit(socket, :apply_now, socket.assigns.selected_file || "all", %{
          status: "error",
          error: "no_coordinator"
        })

        {:noreply,
         put_flash(
           socket,
           :error,
           "No core coordinator found. Ensure core-elx is connected, then retry."
         )}

      {:error, reason} ->
        record_rules_audit(socket, :apply_now, socket.assigns.selected_file || "all", %{
          status: "error",
          error: inspect(reason)
        })

        {:noreply, put_flash(socket, :error, "Apply failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:match_field_defs, @match_field_defs)
      |> assign(:set_field_defs, @set_field_defs)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path={@current_path}
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-2">
          <h1 class="text-2xl font-semibold">Device Enrichment Rules</h1>
          <p class="text-sm opacity-70">
            Typed editor for <code>{@rules_dir}</code>. No raw YAML editing.
          </p>
        </div>

        <div class={ui_alert_class(variant: "info", class: "text-sm")}>
          <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-2 w-full">
            <span>Changes are written to rule files. Use Apply Now to reload core rule cache.</span>
            <.ui_button phx-click="apply_now" id="apply-now" size="xs" variant="primary">
              Apply Now
            </.ui_button>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="sr-ui-card bg-sr-surface border border-sr-line">
            <div class="sr-ui-card-body">
              <div class="flex items-center justify-between">
                <h2 class="sr-ui-card-title text-base">Rule Files</h2>
                <div class="flex flex-wrap items-center justify-end gap-1.5">
                  <.ui_button
                    phx-click="open_import_yaml"
                    id="open-import-yaml"
                    disabled={is_nil(@selected_file)}
                    size="xs"
                    variant="outline"
                    class="text-[11px] leading-none whitespace-nowrap"
                  >
                    Import YAML
                  </.ui_button>
                  <.ui_button
                    phx-click="open_export_yaml"
                    id="open-export-yaml"
                    disabled={is_nil(@selected_file)}
                    size="xs"
                    variant="outline"
                    class="text-[11px] leading-none whitespace-nowrap"
                  >
                    Export YAML
                  </.ui_button>
                  <.ui_button
                    phx-click="open_new_file"
                    id="open-new-file"
                    size="xs"
                    variant="primary"
                    class="text-[11px] leading-none whitespace-nowrap"
                  >
                    New File
                  </.ui_button>
                </div>
              </div>
              <div class="space-y-2">
                <%= for file <- @rule_files do %>
                  <div class="flex items-center gap-2">
                    <.ui_button
                      type="button"
                      size="sm"
                      class="flex-1 justify-start"
                      variant={if(@selected_file == file.name, do: "primary", else: "ghost")}
                      active={@selected_file == file.name}
                      phx-click="select_file"
                      phx-value-file={file.name}
                    >
                      <span>{file.name}</span>
                      <.ui_badge
                        :if={file.source == :builtin}
                        size="xs"
                        variant="ghost"
                        class="ml-auto"
                      >
                        built-in
                      </.ui_badge>
                      <.ui_badge
                        :if={file.source == :override and file.state == :inactive}
                        size="xs"
                        variant="warning"
                        class="ml-auto"
                      >
                        inactive
                      </.ui_badge>
                    </.ui_button>
                    <.ui_button
                      :if={file.source == :override and file.state == :active}
                      phx-click="deactivate_file"
                      phx-value-file={file.name}
                      size="xs"
                      variant="outline"
                    >
                      Deactivate
                    </.ui_button>
                    <.ui_button
                      :if={file.source == :override and file.state == :inactive}
                      phx-click="activate_file"
                      phx-value-file={file.name}
                      size="xs"
                      variant="outline"
                    >
                      Activate
                    </.ui_button>
                    <.ui_button
                      :if={file.source == :override}
                      phx-click="delete_file"
                      phx-value-file={file.name}
                      phx-confirm={"Delete #{file.name}?"}
                      size="xs"
                      variant="outline"
                    >
                      Delete
                    </.ui_button>
                  </div>
                <% end %>
                <p :if={@rule_files == []} class="text-sm opacity-60">No rule files found.</p>
              </div>
            </div>
          </div>

          <div class="sr-ui-card bg-sr-surface border border-sr-line lg:col-span-2">
            <div class="sr-ui-card-body gap-4">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h2 class="sr-ui-card-title text-base">
                  <%= if @selected_file do %>
                    Rules in {@selected_file}
                  <% else %>
                    Select a rule file
                  <% end %>
                </h2>
                <div class="flex flex-wrap items-center justify-end gap-1.5">
                  <.ui_badge
                    :if={@selected_file_source == :builtin}
                    size="sm"
                    variant="info"
                  >
                    Built-in rules
                  </.ui_badge>
                  <.ui_badge
                    :if={@selected_file_source == :override and @selected_file_state == :inactive}
                    size="sm"
                    variant="warning"
                  >
                    Inactive file
                  </.ui_badge>
                  <.ui_button
                    :if={@selected_file}
                    phx-click="reload_file"
                    id="reload-file"
                    size="xs"
                    variant="ghost"
                    class="text-[11px] leading-none whitespace-nowrap"
                  >
                    Reload
                  </.ui_button>
                  <.ui_button
                    phx-click="new_rule"
                    disabled={
                      is_nil(@selected_file) or @selected_file_source != :override or
                        @selected_file_state != :active
                    }
                    id="new-rule"
                    size="xs"
                    variant="outline"
                    class="text-[11px] leading-none whitespace-nowrap"
                  >
                    New Rule
                  </.ui_button>
                </div>
              </div>

              <div
                :if={@selected_file && @rules == []}
                class={ui_alert_class(variant: "info", class: "text-sm")}
              >
                <span>No rules yet in this file.</span>
              </div>

              <div :if={@rules != []}>
                <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
                  <thead>
                    <tr>
                      <th>ID</th>
                      <th>Type</th>
                      <th>Vendor</th>
                      <th>Priority</th>
                      <th>Enabled</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for {rule, idx} <- Enum.with_index(@rules) do %>
                      <tr id={"rule-row-#{idx}"}>
                        <td class="font-mono text-xs">{Map.get(rule, "id")}</td>
                        <td>{get_in(rule, ["set", "type"]) || "-"}</td>
                        <td>{get_in(rule, ["set", "vendor_name"]) || "-"}</td>
                        <td>{Map.get(rule, "priority", 0)}</td>
                        <td>
                          <.ui_badge
                            size="sm"
                            variant={if(Map.get(rule, "enabled", true), do: "success", else: "ghost")}
                          >
                            {if Map.get(rule, "enabled", true), do: "enabled", else: "disabled"}
                          </.ui_badge>
                        </td>
                        <td class="w-[15rem] align-top">
                          <div class="grid grid-cols-3 gap-1.5">
                            <.ui_button
                              phx-click="edit_rule"
                              phx-value-index={idx}
                              size="xs"
                              variant="neutral"
                              class="w-full text-[11px] leading-none whitespace-nowrap"
                            >
                              Edit
                            </.ui_button>
                            <.ui_button
                              phx-click="duplicate_rule"
                              phx-value-index={idx}
                              size="xs"
                              variant="outline"
                              class="w-full text-[11px] leading-none whitespace-nowrap"
                            >
                              Duplicate
                            </.ui_button>
                            <.ui_button
                              phx-click="delete_rule"
                              phx-value-index={idx}
                              size="xs"
                              variant="outline"
                              class="w-full text-[11px] leading-none whitespace-nowrap"
                            >
                              Delete
                            </.ui_button>
                            <.ui_button
                              phx-click="move_rule_up"
                              phx-value-index={idx}
                              disabled={idx == 0}
                              size="xs"
                              variant="outline"
                              class="w-full text-[11px] leading-none whitespace-nowrap"
                            >
                              ↑ Up
                            </.ui_button>
                            <.ui_button
                              phx-click="move_rule_down"
                              phx-value-index={idx}
                              disabled={idx == length(@rules) - 1}
                              size="xs"
                              variant="outline"
                              class="w-full text-[11px] leading-none whitespace-nowrap"
                            >
                              ↓ Down
                            </.ui_button>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>

        <div class="sr-ui-card bg-sr-surface border border-sr-line">
          <div class="sr-ui-card-body">
            <h2 class="sr-ui-card-title text-base">Simulation</h2>
            <p class="text-sm opacity-70">
              Paste a mapper/sync-style payload JSON to preview classification output.
            </p>

            <.form for={@simulation_form} phx-submit="simulate" id="simulation-form" class="space-y-3">
              <textarea
                name="simulation[payload]"
                class={ui_field_class(mono: true, class: "w-full min-h-[220px] py-2.5")}
              >{@simulation_form[:payload].value}</textarea>
              <.ui_button type="submit" size="sm" variant="primary">Run Simulation</.ui_button>
            </.form>

            <div
              :if={@simulation_result}
              class="bg-sr-subtle rounded-sr-surface p-3 text-sm space-y-2"
            >
              <div>
                <span class="font-semibold">Rule:</span> {@simulation_result.classification.rule_id ||
                  "none"}
              </div>
              <div>
                <span class="font-semibold">Source:</span> {@simulation_result.classification.source ||
                  "none"}
              </div>
              <div>
                <span class="font-semibold">Confidence:</span> {@simulation_result.classification.confidence ||
                  "-"}
              </div>
              <div>
                <span class="font-semibold">Vendor:</span> {@simulation_result.classification.vendor_name ||
                  "-"}
              </div>
              <div>
                <span class="font-semibold">Type:</span> {@simulation_result.classification.type ||
                  "-"}
              </div>
              <div>
                <span class="font-semibold">Type ID:</span> {@simulation_result.classification.type_id ||
                  "-"}
              </div>
              <div>
                <span class="font-semibold">Model:</span> {@simulation_result.classification.model ||
                  "-"}
              </div>
              <div>
                <span class="font-semibold">Reason:</span> {@simulation_result.classification.reason ||
                  "-"}
              </div>
            </div>
          </div>
        </div>

        <.ui_modal id="new-rule-file-modal" open={@show_new_file_modal} on_cancel="cancel_new_file">
          <:title>Create Rule File</:title>
          <.form
            for={@new_file_form}
            phx-submit="create_file"
            class="space-y-3"
            id="new-rule-file-form"
          >
            <.input
              field={@new_file_form[:file_name]}
              type="text"
              label="File Name"
              placeholder="custom-overrides.yaml"
            />
            <p class="text-xs text-sr-muted">File name must end in <code>.yaml</code>.</p>
            <div class="flex justify-end gap-2 pt-1">
              <.ui_button type="button" phx-click="cancel_new_file" size="sm" variant="neutral">
                Cancel
              </.ui_button>
              <.ui_button type="submit" size="sm" variant="primary">Create</.ui_button>
            </div>
          </.form>
        </.ui_modal>

        <.ui_modal
          id="import-yaml-modal"
          open={@show_import_modal}
          size="2xl"
          on_cancel="cancel_import_yaml"
        >
          <:title>Import YAML</:title>
          <p class="text-sm text-sr-muted">
            Replace rules in <code class="text-sr-ink">{@selected_file}</code> with validated YAML.
          </p>

          <.form
            for={@import_form}
            phx-submit="import_yaml"
            id="import-yaml-form"
            class="space-y-3"
          >
            <textarea
              name="import[yaml]"
              class={ui_field_class(mono: true, class: "w-full min-h-[320px] py-2.5")}
              placeholder="rules: ..."
            >{@import_form[:yaml].value}</textarea>
            <div class="flex justify-end gap-2 pt-1">
              <.ui_button type="button" phx-click="cancel_import_yaml" size="sm" variant="neutral">
                Cancel
              </.ui_button>
              <.ui_button type="submit" size="sm" variant="primary">Import</.ui_button>
            </div>
          </.form>
        </.ui_modal>

        <.ui_modal
          id="export-yaml-modal"
          open={@show_export_modal}
          size="2xl"
          on_cancel="close_export_yaml"
        >
          <:title>Export YAML</:title>
          <p class="text-sm text-sr-muted">
            Current contents of <code class="text-sr-ink">{@selected_file}</code>.
          </p>
          <textarea
            id="export-yaml-content"
            class={ui_field_class(mono: true, class: "w-full min-h-[320px] py-2.5")}
            readonly
          >{@export_yaml}</textarea>
          <:actions>
            <.ui_button
              type="button"
              phx-click="download_export_yaml"
              id="download-export-yaml"
              size="sm"
              variant="outline"
            >
              Download .yaml
            </.ui_button>
            <.ui_button type="button" phx-click="close_export_yaml" size="sm" variant="primary">
              Close
            </.ui_button>
          </:actions>
        </.ui_modal>

        <.ui_modal
          id="rule-editor-modal"
          open={@show_rule_editor}
          size="2xl"
          on_cancel="attempt_close_rule_editor"
          phx-window-keydown="rule_editor_escape"
          phx-key="escape"
        >
          <:title>
            {if is_nil(@editing_index), do: "New Rule", else: "Edit Rule"}
          </:title>

          <.form
            for={@rule_form}
            phx-change="rule_form_changed"
            phx-submit="save_rule"
            id="rule-editor-form"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <.input field={@rule_form[:id]} type="text" label="Rule ID" />
              <.input field={@rule_form[:reason]} type="text" label="Reason" />
              <.input field={@rule_form[:priority]} type="number" label="Priority" />
              <.input field={@rule_form[:confidence]} type="number" label="Confidence (0-100)" />
            </div>

            <div class="flex flex-col gap-1.5">
              <label class="flex cursor-pointer items-center gap-2 justify-start gap-2">
                <input
                  type="checkbox"
                  name="rule[enabled]"
                  class={ui_checkbox_class()}
                  checked={checkbox_checked?(@rule_form[:enabled].value)}
                />
                <span class="text-sm font-medium text-sr-ink">Enabled</span>
              </label>
            </div>

            <div class="sr-ui-divider">Match Conditions</div>
            <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
              <div class="space-y-2">
                <h4 class="text-sm font-semibold text-sr-ink">ALL</h4>
                <%= for {key, all_field, _any_field} <- @match_field_defs do %>
                  <.input
                    field={@rule_form[all_field]}
                    type="text"
                    label={"#{key} (comma-separated)"}
                  />
                <% end %>
              </div>
              <div class="space-y-2">
                <h4 class="text-sm font-semibold text-sr-ink">ANY</h4>
                <%= for {key, _all_field, any_field} <- @match_field_defs do %>
                  <.input
                    field={@rule_form[any_field]}
                    type="text"
                    label={"#{key} (comma-separated)"}
                  />
                <% end %>
              </div>
            </div>

            <div class="sr-ui-divider">Set Values</div>
            <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
              <%= for {key, set_field} <- @set_field_defs do %>
                <.input field={@rule_form[set_field]} type="text" label={key} />
              <% end %>
            </div>

            <div class="flex justify-end gap-2 pt-1">
              <.ui_button type="button" phx-click="cancel_rule" size="sm" variant="neutral">
                Cancel
              </.ui_button>
              <.ui_button type="submit" size="sm" variant="primary">Save Rule</.ui_button>
            </div>
          </.form>
        </.ui_modal>

        <.ui_modal
          id="discard-rule-modal"
          open={@show_discard_rule_modal}
          size="sm"
          on_cancel="keep_editing_rule"
        >
          <:title>Discard unsaved changes?</:title>
          <p class="text-sm text-sr-muted">
            You have unsaved edits in this rule. Leaving now will lose those changes.
          </p>
          <:actions>
            <.ui_button type="button" phx-click="keep_editing_rule" size="sm" variant="outline">
              Keep Editing
            </.ui_button>
            <.ui_button type="button" phx-click="discard_rule_changes" size="sm" variant="danger">
              Discard Changes
            </.ui_button>
          </:actions>
        </.ui_modal>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  defp can_manage?(scope), do: RBAC.can?(scope, "settings.networks.manage")

  defp normalize_simulation_update(update) do
    metadata =
      case Map.get(update, "metadata") || Map.get(update, :metadata) do
        map when is_map(map) -> map
        _ -> %{}
      end

    %{
      hostname: Map.get(update, "hostname") || Map.get(update, :hostname) || "",
      source: Map.get(update, "source") || Map.get(update, :source) || "mapper",
      metadata: metadata
    }
  end

  defp apply_rules_now do
    case ServiceRadar.Cluster.ClusterStatus.find_coordinator() do
      nil ->
        {:error, :no_coordinator}

      coordinator_node ->
        case :rpc.call(
               coordinator_node,
               DeviceEnrichmentRules,
               :reload_cluster,
               [],
               10_000
             ) do
          {:ok, nodes} when is_list(nodes) ->
            {:ok, nodes}

          {:error, details} ->
            {:error, details}

          {:badrpc, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_response, other}}
        end
    end
  rescue
    e -> {:error, {:exception, e}}
  end

  defp rules_dir do
    Application.get_env(:serviceradar_web_ng, :device_enrichment_rules_dir, @default_rules_dir)
  end

  defp record_rules_audit(socket, operation, file_name, details) do
    actor = actor_from_scope(socket.assigns.current_scope)

    payload =
      details
      |> Map.put_new(:operation, to_string(operation))
      |> Map.put_new(:rule_file, file_name)

    :ok =
      AuditWriter.write_async(
        action: audit_action(operation),
        resource_type: "device_enrichment_rules",
        resource_id: to_string(file_name || "all"),
        resource_name: to_string(file_name || "all"),
        actor: actor,
        details: payload
      )

    :ok
  rescue
    error ->
      Logger.warning("Failed to write device enrichment audit event: #{inspect(error)}")
      :ok
  end

  defp audit_action(:create_file), do: :create
  defp audit_action(:activate_file), do: :update
  defp audit_action(:deactivate_file), do: :update
  defp audit_action(:delete_file), do: :delete
  defp audit_action(:save_rule), do: :update
  defp audit_action(:delete_rule), do: :update
  defp audit_action(:duplicate_rule), do: :update
  defp audit_action(:move_rule), do: :update
  defp audit_action(:apply_now), do: :update
  defp audit_action(:import_yaml), do: :update
  defp audit_action(:export_yaml), do: :read

  defp actor_from_scope(%{user: user}) when is_map(user) do
    %{
      id: Map.get(user, :id) || Map.get(user, "id"),
      email: Map.get(user, :email) || Map.get(user, "email")
    }
  end

  defp actor_from_scope(_), do: nil

  defp rules_change_summary(before_rules, after_rules) do
    %{
      before_count: length(before_rules),
      after_count: length(after_rules),
      before_fingerprint: rules_fingerprint(before_rules),
      after_fingerprint: rules_fingerprint(after_rules)
    }
  end

  defp rules_fingerprint(rules) do
    rules
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp list_rule_files(dir) do
    override_files =
      dir
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    inactive_override_files =
      dir
      |> Path.join("*.yaml.disabled")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> MapSet.new(&String.trim_trailing(&1, ".disabled"))

    builtin_files =
      builtin_rules_dir()
      |> Path.join("*.yaml")
      |> Path.wildcard()
      |> MapSet.new(&Path.basename/1)

    all_names =
      override_files
      |> MapSet.union(inactive_override_files)
      |> MapSet.union(builtin_files)
      |> MapSet.to_list()
      |> Enum.sort()

    Enum.map(all_names, fn name ->
      {source, state} =
        cond do
          MapSet.member?(override_files, name) -> {:override, :active}
          MapSet.member?(inactive_override_files, name) -> {:override, :inactive}
          true -> {:builtin, :active}
        end

      %{name: name, source: source, state: state}
    end)
  end

  defp load_selected_file(socket, file) do
    with {:ok, normalized_file} <- normalize_file_name(file),
         {:ok, content, source, state} <-
           read_rule_file(socket.assigns.rules_dir, normalized_file),
         {:ok, rules} <- parse_file_rules(content, normalized_file) do
      socket
      |> assign(:selected_file, normalized_file)
      |> assign(:selected_file_source, source)
      |> assign(:selected_file_state, state)
      |> assign(
        :selected_file_mtime,
        if(source == :override and state == :active,
          do: file_mtime(socket.assigns.rules_dir, normalized_file)
        )
      )
      |> assign(:rules, rules)
    else
      {:error, reason} ->
        socket
        |> put_flash(:error, reason)
        |> assign(:selected_file, nil)
        |> assign(:selected_file_source, nil)
        |> assign(:selected_file_state, nil)
        |> assign(:selected_file_mtime, nil)
        |> assign(:rules, [])
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp read_rule_file(rules_dir, file_name) do
    override_path = Path.join(rules_dir, file_name)
    inactive_override_path = override_path <> ".disabled"
    builtin_path = Path.join(builtin_rules_dir(), file_name)

    cond do
      File.exists?(override_path) ->
        case File.read(override_path) do
          {:ok, content} -> {:ok, content, :override, :active}
          {:error, reason} -> {:error, "Could not read #{file_name}: #{inspect(reason)}"}
        end

      File.exists?(inactive_override_path) ->
        case File.read(inactive_override_path) do
          {:ok, content} -> {:ok, content, :override, :inactive}
          {:error, reason} -> {:error, "Could not read #{file_name}: #{inspect(reason)}"}
        end

      File.exists?(builtin_path) ->
        case File.read(builtin_path) do
          {:ok, content} -> {:ok, content, :builtin, :active}
          {:error, reason} -> {:error, "Could not read #{file_name}: #{inspect(reason)}"}
        end

      true ->
        {:error, "Rule file not found: #{file_name}"}
    end
  end

  defp builtin_rules_dir do
    case :code.priv_dir(:serviceradar_core) do
      priv_dir when is_list(priv_dir) ->
        Path.join([List.to_string(priv_dir), "device_enrichment", "rules"])

      _ ->
        ""
    end
  end

  defp ensure_selected_editable(socket) do
    cond do
      is_nil(socket.assigns.selected_file) ->
        {:error, "Select a rule file first"}

      socket.assigns.selected_file_source != :override ->
        {:error, "Built-in files are read-only. Create an override file to edit."}

      socket.assigns.selected_file_state != :active ->
        {:error, "File is inactive. Activate it before editing."}

      true ->
        :ok
    end
  end

  defp deactivate_override_file(rules_dir, file_name) do
    active_path = Path.join(rules_dir, file_name)
    inactive_path = active_path <> ".disabled"

    cond do
      not File.exists?(active_path) ->
        {:error, "Only active override files can be deactivated"}

      File.exists?(inactive_path) ->
        {:error, "Inactive file already exists for #{file_name}"}

      true ->
        File.rename(active_path, inactive_path)
    end
  end

  defp activate_override_file(rules_dir, file_name) do
    active_path = Path.join(rules_dir, file_name)
    inactive_path = active_path <> ".disabled"

    cond do
      File.exists?(active_path) ->
        {:error, "#{file_name} is already active"}

      not File.exists?(inactive_path) ->
        {:error, "Inactive override file not found for #{file_name}"}

      true ->
        File.rename(inactive_path, active_path)
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp delete_override_file(rules_dir, file_name) do
    active_path = Path.join(rules_dir, file_name)
    inactive_path = active_path <> ".disabled"

    cond do
      File.exists?(active_path) ->
        File.rm(active_path)

      File.exists?(inactive_path) ->
        File.rm(inactive_path)

      true ->
        {:error, "Override file not found for #{file_name}"}
    end
  end

  defp parse_file_rules(content, file_name) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{"rules" => rules}} when is_list(rules) ->
        {:ok, Enum.map(rules, &stringify_map_keys/1)}

      {:ok, %{rules: rules}} when is_list(rules) ->
        {:ok, Enum.map(rules, &stringify_map_keys/1)}

      {:ok, _} ->
        {:error, "#{file_name} is missing a top-level rules list"}

      {:error, reason} ->
        {:error, "Could not parse #{file_name}: #{inspect(reason)}"}
    end
  end

  defp stringify_map_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key =
        case key do
          k when is_atom(k) -> Atom.to_string(k)
          k -> to_string(k)
        end

      {normalized_key, stringify_map_keys(value)}
    end)
  end

  defp stringify_map_keys(list) when is_list(list), do: Enum.map(list, &stringify_map_keys/1)
  defp stringify_map_keys(value), do: value

  defp normalize_file_name(file_name) when is_binary(file_name) do
    trimmed = String.trim(file_name)

    cond do
      trimmed == "" ->
        {:error, "File name is required"}

      trimmed != Path.basename(trimmed) ->
        {:error, "File name must not include directories"}

      not String.ends_with?(String.downcase(trimmed), ".yaml") ->
        {:error, "File name must end with .yaml"}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_file_name(_), do: {:error, "Invalid file name"}

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp parse_index(index) when is_integer(index), do: index
  defp parse_index(_), do: -1

  defp remove_rule_at(rules, idx) when idx >= 0 do
    if idx < length(rules) do
      {:ok, List.delete_at(rules, idx)}
    else
      {:error, "Rule not found"}
    end
  end

  defp remove_rule_at(_rules, _idx), do: {:error, "Rule not found"}

  defp upsert_rule(rules, nil, rule), do: {:ok, rules ++ [rule]}

  defp upsert_rule(rules, idx, rule) when is_integer(idx) and idx >= 0 do
    if idx < length(rules) do
      {:ok, List.replace_at(rules, idx, rule)}
    else
      {:error, "Rule not found"}
    end
  end

  defp upsert_rule(_rules, _idx, _rule), do: {:error, "Rule not found"}

  defp move_rule(socket, idx, direction) when idx >= 0 and direction in [-1, 1] do
    target = idx + direction
    rules = socket.assigns.rules

    cond do
      is_nil(socket.assigns.selected_file) ->
        {:noreply, put_flash(socket, :error, "Select a file first")}

      socket.assigns.selected_file_source != :override ->
        {:noreply, put_flash(socket, :error, "Built-in files are read-only")}

      socket.assigns.selected_file_state != :active ->
        {:noreply, put_flash(socket, :error, "File is inactive. Activate it before editing.")}

      idx >= length(rules) or target < 0 or target >= length(rules) ->
        {:noreply, socket}

      true ->
        swapped =
          rules
          |> List.replace_at(idx, Enum.at(rules, target))
          |> List.replace_at(target, Enum.at(rules, idx))

        with {:ok, validated_rules} <- validate_rules(swapped, socket.assigns.selected_file),
             :ok <-
               write_rules_file(
                 socket.assigns.rules_dir,
                 socket.assigns.selected_file,
                 validated_rules,
                 socket.assigns.selected_file_mtime
               ) do
          record_rules_audit(socket, :move_rule, socket.assigns.selected_file, %{
            from_index: idx,
            to_index: target,
            rules: rules_change_summary(rules, validated_rules),
            status: "success"
          })

          {:noreply,
           socket
           |> assign(:rules, validated_rules)
           |> load_selected_file(socket.assigns.selected_file)
           |> put_flash(:info, "Rule order updated")}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, reason)}
        end
    end
  end

  defp move_rule(socket, _idx, _direction), do: {:noreply, socket}

  defp validate_rules(rules, file_name) do
    if rules == [] do
      {:ok, []}
    else
      case DeviceEnrichmentRules.validate_rule_document(%{"rules" => rules}, file: file_name) do
        {:ok, _normalized} -> {:ok, rules}
        {:error, errors} -> {:error, Enum.join(errors, "; ")}
      end
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp write_rules_file(dir, file_name, rules, expected_mtime \\ :any) do
    with :ok <- File.mkdir_p(dir),
         {:ok, normalized_name} <- normalize_file_name(file_name),
         :ok <- assert_unmodified(dir, normalized_name, expected_mtime),
         yaml = render_rules_yaml(rules),
         :ok <- File.write(Path.join(dir, normalized_name), yaml) do
      :ok
    else
      {:error, :stale_file} ->
        {:error, "Rule file changed on disk. Click Reload and re-apply your changes."}

      {:error, reason} ->
        {:error, "Failed to write file: #{inspect(reason)}"}
    end
  end

  defp assert_unmodified(_dir, _file_name, :any), do: :ok
  defp assert_unmodified(_dir, _file_name, nil), do: :ok

  defp assert_unmodified(dir, file_name, expected_mtime) do
    if file_mtime(dir, file_name) == expected_mtime do
      :ok
    else
      {:error, :stale_file}
    end
  end

  defp file_mtime(dir, file_name) do
    path = Path.join(dir, file_name)

    case File.stat(path) do
      {:ok, stat} -> stat.mtime
      _ -> nil
    end
  end

  defp render_rules_yaml(rules) do
    if rules == [] do
      "rules: []\n"
    else
      "rules:\n" <> Enum.map_join(rules, "\n", &render_rule_yaml/1)
    end
  end

  defp render_rule_yaml(rule) do
    lines =
      List.flatten([
        "  - id: #{yaml_scalar(Map.get(rule, "id"))}",
        "    enabled: #{if(Map.get(rule, "enabled", true), do: "true", else: "false")}",
        "    priority: #{Map.get(rule, "priority", 0)}",
        "    confidence: #{Map.get(rule, "confidence", 50)}",
        "    reason: #{yaml_scalar(Map.get(rule, "reason", ""))}",
        render_match_yaml(Map.get(rule, "match", %{})),
        render_set_yaml(Map.get(rule, "set", %{}))
      ])

    Enum.join(lines, "\n")
  end

  defp render_match_yaml(match) when is_map(match) do
    all = Map.get(match, "all", %{}) || %{}
    any = Map.get(match, "any", %{}) || %{}

    [
      "    match:",
      "      all:",
      render_condition_map_yaml(all, 8),
      "      any:",
      render_condition_map_yaml(any, 8)
    ]
  end

  defp render_set_yaml(set) when is_map(set) do
    keys =
      set
      |> Map.keys()
      |> Enum.sort()

    lines =
      Enum.map(keys, fn key ->
        "      #{key}: #{render_value_yaml(Map.get(set, key), 6)}"
      end)

    ["    set:" | lines]
  end

  defp render_condition_map_yaml(map, indent) when is_map(map) do
    prefix = String.duplicate(" ", indent)

    if map_size(map) == 0 do
      "#{prefix}{}"
    else
      map
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", fn {k, v} -> "#{prefix}#{k}: #{render_value_yaml(v, indent)}" end)
    end
  end

  defp render_value_yaml(value, _indent) when is_list(value) do
    values = Enum.map(value, &yaml_scalar/1)
    "[#{Enum.join(values, ", ")}]"
  end

  defp render_value_yaml(value, _indent), do: yaml_scalar(value)

  defp yaml_scalar(value) when is_boolean(value), do: if(value, do: "true", else: "false")
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: :erlang.float_to_binary(value)

  defp yaml_scalar(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp checkbox_checked?(value), do: to_bool(value)

  defp to_bool(value) when value in [true, "true", "on", "1", 1], do: true
  defp to_bool(_), do: false

  defp csv_values(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_csv_for_key(key, value) do
    values = csv_values(value)

    case key do
      "ip_forwarding" ->
        Enum.map(values, &parse_ip_forwarding_candidate/1)

      _ ->
        values
    end
  end

  defp parse_ip_forwarding_candidate(candidate) do
    case Integer.parse(candidate) do
      {int, ""} -> int
      _ -> candidate
    end
  end

  defp default_rule_form do
    add_default_match_fields(%{
      "id" => "",
      "enabled" => "true",
      "priority" => "1000",
      "confidence" => "90",
      "reason" => "",
      "set_vendor_name" => "",
      "set_model" => "",
      "set_type" => "",
      "set_type_id" => "",
      "set_model_from_sys_descr_prefix" => ""
    })
  end

  defp default_simulation_payload do
    ~s|{
  "hostname": "farm01",
  "source": "mapper",
  "metadata": {
    "sys_object_id": ".1.3.6.1.4.1.8072.3.2.10",
    "sys_descr": "Ubiquiti UniFi UDM-Pro 4.4.6 Linux 4.19.152 al324",
    "sys_name": "farm01",
    "ip_forwarding": "1"
  }
}|
  end

  defp add_default_match_fields(map) do
    Enum.reduce(@match_field_defs, map, fn {_key, all_field, any_field}, acc ->
      acc
      |> Map.put(to_string(all_field), "")
      |> Map.put(to_string(any_field), "")
    end)
  end

  defp rule_to_form(rule) do
    base =
      default_rule_form()
      |> Map.put("id", to_string(Map.get(rule, "id", "")))
      |> Map.put("enabled", if(Map.get(rule, "enabled", true), do: "true", else: "false"))
      |> Map.put("priority", to_string(Map.get(rule, "priority", 0)))
      |> Map.put("confidence", to_string(Map.get(rule, "confidence", 50)))
      |> Map.put("reason", to_string(Map.get(rule, "reason", "")))
      |> Map.put("set_vendor_name", to_string(get_in(rule, ["set", "vendor_name"]) || ""))
      |> Map.put("set_model", to_string(get_in(rule, ["set", "model"]) || ""))
      |> Map.put("set_type", to_string(get_in(rule, ["set", "type"]) || ""))
      |> Map.put("set_type_id", to_string(get_in(rule, ["set", "type_id"]) || ""))
      |> Map.put(
        "set_model_from_sys_descr_prefix",
        to_string(get_in(rule, ["set", "model_from_sys_descr_prefix"]) || "")
      )

    Enum.reduce(@match_field_defs, base, fn {key, all_field, any_field}, acc ->
      all_value = rule |> get_in(["match", "all", key]) |> value_to_csv()
      any_value = rule |> get_in(["match", "any", key]) |> value_to_csv()

      acc
      |> Map.put(to_string(all_field), all_value)
      |> Map.put(to_string(any_field), any_value)
    end)
  end

  defp value_to_csv(nil), do: ""
  defp value_to_csv(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp value_to_csv(value), do: to_string(value)

  defp duplicate_rule(rule, existing_rules) do
    base_id = to_string(Map.get(rule, "id", "rule"))
    next_id = next_duplicate_id(base_id, existing_rules, 1)

    rule
    |> Map.put("id", next_id)
    |> Map.put("enabled", false)
    |> Map.put("reason", "#{Map.get(rule, "reason", "Duplicated")} (copy)")
  end

  defp next_duplicate_id(base_id, existing_rules, attempt) do
    candidate = "#{base_id}-copy-#{attempt}"

    if Enum.any?(existing_rules, fn rule -> to_string(Map.get(rule, "id", "")) == candidate end) do
      next_duplicate_id(base_id, existing_rules, attempt + 1)
    else
      candidate
    end
  end

  defp close_rule_editor(socket) do
    if socket.assigns.rule_form_dirty do
      {:noreply, assign(socket, :show_discard_rule_modal, true)}
    else
      {:noreply, reset_rule_editor(socket)}
    end
  end

  defp reset_rule_editor(socket) do
    socket
    |> assign(:show_rule_editor, false)
    |> assign(:show_discard_rule_modal, false)
    |> assign(:editing_index, nil)
    |> assign(:rule_form_dirty, false)
  end

  defp form_to_rule(params) do
    id = String.trim(Map.get(params, "id", ""))

    if id == "" do
      {:error, "Rule ID is required"}
    else
      with {:ok, priority} <- parse_int_field(params, "priority", "Priority"),
           {:ok, confidence} <- parse_int_field(params, "confidence", "Confidence"),
           :ok <- validate_confidence(confidence),
           {:ok, set} <- build_set_map(params),
           {:ok, match} <- build_match_map(params) do
        {:ok,
         %{
           "id" => id,
           "enabled" => to_bool(Map.get(params, "enabled", "false")),
           "priority" => priority,
           "confidence" => confidence,
           "reason" => String.trim(Map.get(params, "reason", "")),
           "match" => match,
           "set" => set
         }}
      end
    end
  end

  defp parse_int_field(params, key, label) do
    value = params |> Map.get(key, "") |> String.trim()

    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "#{label} must be an integer"}
    end
  end

  defp validate_confidence(value) when value >= 0 and value <= 100, do: :ok
  defp validate_confidence(_), do: {:error, "Confidence must be between 0 and 100"}

  defp build_set_map(params) do
    set =
      Enum.reduce(@set_keys, %{}, fn key, acc ->
        value = params |> Map.get("set_#{key}", "") |> String.trim()
        maybe_put_set_value(acc, key, value)
      end)

    if map_size(set) == 0 do
      {:error, "At least one set field is required"}
    else
      {:ok, set}
    end
  end

  defp maybe_put_set_value(acc, _key, ""), do: acc

  defp maybe_put_set_value(acc, "type_id", value) do
    parsed =
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> value
      end

    Map.put(acc, "type_id", parsed)
  end

  defp maybe_put_set_value(acc, key, value), do: Map.put(acc, key, value)

  defp build_match_map(params) do
    all_map =
      Enum.reduce(@match_keys, %{}, fn key, acc ->
        value = params |> Map.get("all_#{key}", "") |> String.trim()

        if value == "" do
          acc
        else
          Map.put(acc, key, parse_csv_for_key(key, value))
        end
      end)

    any_map =
      Enum.reduce(@match_keys, %{}, fn key, acc ->
        value = params |> Map.get("any_#{key}", "") |> String.trim()

        if value == "" do
          acc
        else
          Map.put(acc, key, parse_csv_for_key(key, value))
        end
      end)

    if map_size(all_map) == 0 and map_size(any_map) == 0 do
      {:error, "At least one match condition is required"}
    else
      {:ok, %{"all" => all_map, "any" => any_map}}
    end
  end
end
