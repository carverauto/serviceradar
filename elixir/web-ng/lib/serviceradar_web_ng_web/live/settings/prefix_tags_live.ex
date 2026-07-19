defmodule ServiceRadarWebNGWeb.Settings.PrefixTagsLive do
  @moduledoc """
  Settings UI for listing and editing manual IP/CIDR prefix tags, with a
  read-only view of imported sources (NetBox, provider, ti, dns-policy).
  """

  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.PrefixTags.Manual
  alias ServiceRadar.PrefixTags.PrefixTag
  alias ServiceRadar.PrefixTags.Store
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Settings.Shell

  @current_path "/settings/networks/prefix-tags"
  @permission "settings.prefix_tags.manage"
  @source_tabs ~w(manual netbox provider ti dns-policy)

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      {:ok,
       socket
       |> assign(:page_title, "Prefix Tags")
       |> assign(:current_path, @current_path)
       |> assign(:source_tab, "manual")
       |> assign(:source_tabs, @source_tabs)
       |> assign(:tags, [])
       |> assign(:form_mode, nil)
       |> assign(:editing, nil)
       |> assign(:form, empty_form())
       |> assign(:preview_ip, "")
       |> assign(:preview_chain, nil)
       |> assign(:preview_error, nil)
       |> assign(:store_stats, Store.stats())
       |> assign(:sources_label, "—")
       |> assign(:loading?, true)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Not authorized to manage prefix tags")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = normalize_tab(Map.get(params, "source"))

    socket =
      socket
      |> assign(:source_tab, tab)
      |> assign(:form_mode, nil)
      |> assign(:editing, nil)
      |> assign(:form, empty_form())

    if connected?(socket) do
      {:noreply, reload_tags(socket)}
    else
      {:noreply, assign(socket, :loading?, false)}
    end
  end

  @impl true
  def handle_event("select_source", %{"source" => source}, socket) do
    {:noreply, push_patch(socket, to: ~p"/settings/networks/prefix-tags?source=#{normalize_tab(source)}")}
  end

  def handle_event("new", _params, socket) do
    if socket.assigns.source_tab == "manual" do
      {:noreply,
       socket
       |> assign(:form_mode, :new)
       |> assign(:editing, nil)
       |> assign(:form, empty_form())}
    else
      {:noreply, put_flash(socket, :error, "Only the manual source is editable")}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.tags, &(to_string(&1.id) == to_string(id))) do
      nil ->
        {:noreply, put_flash(socket, :error, "Tag not found")}

      %PrefixTag{} = tag ->
        if manual_tag?(tag) do
          {:noreply,
           socket
           |> assign(:form_mode, :edit)
           |> assign(:editing, tag)
           |> assign(:form, tag_to_form(tag))}
        else
          {:noreply, put_flash(socket, :error, "Imported tags are read-only")}
        end
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:form_mode, nil)
     |> assign(:editing, nil)
     |> assign(:form, empty_form())}
  end

  def handle_event("save", %{"prefix_tag" => params}, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      do_save(socket, params)
    else
      {:noreply,
       socket
       |> put_flash(:error, "Not authorized")
       |> redirect(to: ~p"/settings/profile")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      case Enum.find(socket.assigns.tags, &(to_string(&1.id) == to_string(id))) do
        nil ->
          {:noreply, put_flash(socket, :error, "Tag not found")}

        tag ->
          case Manual.destroy(tag, scope: socket.assigns.current_scope) do
            :ok ->
              {:noreply,
               socket
               |> put_flash(:info, "Prefix tag deleted")
               |> assign(:form_mode, nil)
               |> assign(:editing, nil)
               |> reload_tags()}

            {:error, :not_manual} ->
              {:noreply, put_flash(socket, :error, "Imported tags cannot be deleted here")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Delete failed: #{format_error(reason)}")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("preview", params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      ip =
        params
        |> Map.get("ip", "")
        |> to_string()
        |> String.trim()

      if ip == "" do
        {:noreply,
         socket
         |> assign(:preview_ip, "")
         |> assign(:preview_chain, nil)
         |> assign(:preview_error, "Enter an IP address")}
      else
        chain =
          try do
            Store.lookup(ip)
          rescue
            e -> {:error, Exception.message(e)}
          end

        case chain do
          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:preview_ip, ip)
             |> assign(:preview_chain, nil)
             |> assign(:preview_error, reason)}

          list when is_list(list) ->
            {:noreply,
             socket
             |> assign(:preview_ip, ip)
             |> assign(:preview_chain, list)
             |> assign(:preview_error, nil)}
        end
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  def handle_event("reload_trie", _params, socket) do
    if RBAC.can?(socket.assigns.current_scope, @permission) do
      _ = ServiceRadar.PrefixTags.Loader.reload()

      {:noreply,
       socket
       |> assign(:store_stats, Store.stats())
       |> put_flash(:info, "Prefix-tag tries reloaded on this node")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
    >
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
        <div class="mx-auto w-full max-w-6xl p-6 space-y-6">
          <header class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold text-base-content">Prefix Tags</h1>
              <p class="text-sm text-base-content/70 mt-1 max-w-2xl">
                Manage manual IP/CIDR → tag mappings used by flow enrichment.
                NetBox, provider, threat-intel, and DNS-policy sources are imported
                automatically and shown read-only.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <.ui_button variant="ghost" size="sm" phx-click="reload_trie">
                Reload local trie
              </.ui_button>
              <.ui_button
                :if={@source_tab == "manual"}
                variant="primary"
                size="sm"
                phx-click="new"
              >
                Add prefix
              </.ui_button>
            </div>
          </header>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">Active trie stats</div>
            </:header>
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm font-mono">
              <div>
                <div class="text-xs uppercase text-base-content/50">IPv4</div>
                <div>{Map.get(@store_stats, :ipv4_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-base-content/50">IPv6</div>
                <div>{Map.get(@store_stats, :ipv6_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-base-content/50">Total</div>
                <div>{Map.get(@store_stats, :total_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-base-content/50">Sources</div>
                <div>{@sources_label}</div>
              </div>
            </div>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="text-sm font-semibold">IP preview</div>
            </:header>
            <form phx-submit="preview" class="flex flex-wrap items-end gap-2">
              <div class="grow min-w-48">
                <label class="text-xs uppercase tracking-wider text-base-content/60">
                  IP address
                </label>
                <input
                  type="text"
                  name="ip"
                  value={@preview_ip}
                  placeholder="10.1.2.3"
                  class="input input-bordered input-sm w-full font-mono"
                  autocomplete="off"
                />
              </div>
              <.ui_button type="submit" size="sm" variant="primary">Preview</.ui_button>
            </form>
            <div :if={@preview_error} class="mt-3 alert alert-warning text-sm">
              {@preview_error}
            </div>
            <div :if={is_list(@preview_chain)} class="mt-3 space-y-2">
              <%= if @preview_chain == [] do %>
                <p class="text-sm text-base-content/60">No matching prefixes for this address.</p>
              <% else %>
                <div
                  :for={match <- @preview_chain}
                  class="rounded-lg border border-base-200 bg-base-200/30 p-2"
                >
                  <div class="font-mono text-xs text-base-content/70">
                    {Map.get(match, :prefix) || "—"}
                    <span
                      :if={src = Map.get(match, :source)}
                      class="ml-2 badge badge-ghost badge-xs"
                    >
                      {src}
                    </span>
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <span
                      :for={tag <- List.wrap(Map.get(match, :tags) || [])}
                      class="badge badge-outline badge-xs font-mono"
                    >
                      {tag}
                    </span>
                  </div>
                </div>
              <% end %>
            </div>
          </.ui_panel>

          <div class="tabs tabs-boxed bg-base-200/40 p-1 w-fit flex-wrap">
            <button
              :for={tab <- @source_tabs}
              type="button"
              phx-click="select_source"
              phx-value-source={tab}
              class={["tab", @source_tab == tab && "tab-active"]}
            >
              {tab}
            </button>
          </div>

          <.ui_panel :if={@form_mode in [:new, :edit]}>
            <:header>
              <div class="text-sm font-semibold">
                {if @form_mode == :new, do: "New manual prefix", else: "Edit manual prefix"}
              </div>
            </:header>
            <form phx-submit="save" id="prefix-tag-form" class="space-y-4">
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div class="form-control">
                  <label class="label"><span class="label-text">Prefix (CIDR)</span></label>
                  <input
                    type="text"
                    name="prefix_tag[prefix]"
                    value={@form["prefix"]}
                    required
                    placeholder="10.1.2.0/24"
                    class="input input-bordered input-sm font-mono"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">VRF (optional)</span></label>
                  <input
                    type="text"
                    name="prefix_tag[vrf]"
                    value={@form["vrf"]}
                    class="input input-bordered input-sm font-mono"
                  />
                </div>
                <div class="form-control sm:col-span-2">
                  <label class="label">
                    <span class="label-text">Tags (comma or space separated)</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[tags]"
                    value={@form["tags"]}
                    required
                    placeholder="site:hq role:wifi"
                    class="input input-bordered input-sm font-mono"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Site</span></label>
                  <input
                    type="text"
                    name="prefix_tag[site]"
                    value={@form["site"]}
                    class="input input-bordered input-sm"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Role</span></label>
                  <input
                    type="text"
                    name="prefix_tag[role]"
                    value={@form["role"]}
                    class="input input-bordered input-sm"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Tenant</span></label>
                  <input
                    type="text"
                    name="prefix_tag[tenant]"
                    value={@form["tenant"]}
                    class="input input-bordered input-sm"
                  />
                </div>
                <div class="form-control">
                  <label class="label"><span class="label-text">Status</span></label>
                  <input
                    type="text"
                    name="prefix_tag[status]"
                    value={@form["status"]}
                    class="input input-bordered input-sm"
                  />
                </div>
              </div>
              <div class="flex justify-end gap-2">
                <.ui_button type="button" variant="ghost" size="sm" phx-click="cancel_form">
                  Cancel
                </.ui_button>
                <.ui_button type="submit" variant="primary" size="sm">Save</.ui_button>
              </div>
            </form>
          </.ui_panel>

          <.ui_panel>
            <:header>
              <div class="flex items-center justify-between gap-2">
                <div class="text-sm font-semibold">
                  {@source_tab} prefixes
                  <span class="font-normal text-base-content/50">({length(@tags)})</span>
                </div>
                <div
                  :if={@source_tab != "manual"}
                  class="text-xs text-base-content/50"
                >
                  Read-only imported source
                </div>
              </div>
            </:header>

            <div :if={@loading?} class="py-8 text-center text-sm text-base-content/60">
              Loading…
            </div>

            <div
              :if={not @loading? and @tags == []}
              class="py-8 text-center text-sm text-base-content/60"
            >
              No prefixes for this source yet.
              <span :if={@source_tab == "manual"}>Use “Add prefix” to create one.</span>
            </div>

            <div :if={not @loading? and @tags != []} class="overflow-x-auto">
              <table class="table table-sm table-zebra w-full">
                <thead>
                  <tr>
                    <th>Prefix</th>
                    <th>VRF</th>
                    <th>Tags</th>
                    <th>Site / Role</th>
                    <th :if={@source_tab == "manual"} class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={tag <- @tags}>
                    <td class="font-mono text-xs whitespace-nowrap">{tag.prefix}</td>
                    <td class="font-mono text-xs">{tag.vrf || "—"}</td>
                    <td>
                      <div class="flex flex-wrap gap-1">
                        <span
                          :for={t <- List.wrap(tag.tags)}
                          class="badge badge-outline badge-xs font-mono"
                        >
                          {t}
                        </span>
                      </div>
                    </td>
                    <td class="text-xs text-base-content/70">
                      {site_role_label(tag)}
                    </td>
                    <td :if={@source_tab == "manual"} class="text-right whitespace-nowrap">
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        phx-click="edit"
                        phx-value-id={tag.id}
                      >
                        Edit
                      </.ui_button>
                      <.ui_button
                        size="xs"
                        variant="ghost"
                        phx-click="delete"
                        phx-value-id={tag.id}
                        phx-confirm={"Delete #{tag.prefix}?"}
                      >
                        Delete
                      </.ui_button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.ui_panel>
        </div>
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end

  ## -- private ---------------------------------------------------------------

  defp do_save(socket, params) do
    attrs = normalize_form_params(params)
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.form_mode do
        :new ->
          Manual.create(attrs, scope: scope)

        :edit ->
          Manual.update(socket.assigns.editing, attrs, scope: scope)

        _ ->
          {:error, :no_form}
      end

    case result do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prefix tag saved")
         |> assign(:form_mode, nil)
         |> assign(:editing, nil)
         |> assign(:form, empty_form())
         |> reload_tags()}

      {:error, :not_manual} ->
        {:noreply, put_flash(socket, :error, "Imported tags cannot be edited")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, Map.merge(socket.assigns.form, stringify_map(params)))
         |> put_flash(:error, "Save failed: #{format_error(reason)}")}
    end
  end

  defp reload_tags(socket) do
    scope = socket.assigns.current_scope
    source = socket.assigns.source_tab

    tags =
      case Manual.list(source: source, scope: scope, limit: 500) do
        {:ok, list} -> list
        {:error, _} -> []
      end

    stats = Store.stats()

    sources_label =
      case stats do
        %{sources: %{} = sources} ->
          keys = sources |> Map.keys() |> Enum.sort()
          if keys == [], do: "—", else: Enum.join(keys, ", ")

        _ ->
          "—"
      end

    socket
    |> assign(:tags, tags)
    |> assign(:store_stats, stats)
    |> assign(:sources_label, sources_label)
    |> assign(:loading?, false)
  end

  defp site_role_label(%PrefixTag{} = tag) do
    case Enum.reject([tag.site, tag.role], &(is_nil(&1) or &1 == "")) do
      [] -> "—"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp normalize_tab(nil), do: "manual"
  defp normalize_tab(""), do: "manual"

  defp normalize_tab(tab) when is_binary(tab) do
    if tab in @source_tabs, do: tab, else: "manual"
  end

  defp normalize_tab(_), do: "manual"

  defp empty_form do
    %{
      "prefix" => "",
      "vrf" => "",
      "tags" => "",
      "site" => "",
      "role" => "",
      "tenant" => "",
      "status" => ""
    }
  end

  defp tag_to_form(%PrefixTag{} = tag) do
    %{
      "prefix" => to_string(tag.prefix || ""),
      "vrf" => tag.vrf || "",
      "tags" => tag.tags |> List.wrap() |> Enum.join(" "),
      "site" => tag.site || "",
      "role" => tag.role || "",
      "tenant" => tag.tenant || "",
      "status" => tag.status || ""
    }
  end

  defp normalize_form_params(params) when is_map(params) do
    params = stringify_map(params)

    %{
      "prefix" => String.trim(params["prefix"] || ""),
      "vrf" => blank_to_nil(params["vrf"]),
      "tags" => Manual.parse_tags_input(params["tags"]),
      "site" => blank_to_nil(params["site"]),
      "role" => blank_to_nil(params["role"]),
      "tenant" => blank_to_nil(params["tenant"]),
      "status" => blank_to_nil(params["status"])
    }
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      s -> s
    end
  end

  defp blank_to_nil(value), do: value

  defp stringify_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp manual_tag?(%PrefixTag{snapshot: %{source: "manual"}}), do: true
  defp manual_tag?(%PrefixTag{}), do: false

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", fn
      %{message: msg} when is_binary(msg) -> msg
      other -> inspect(other)
    end)
  end

  defp format_error(other), do: inspect(other)
end
