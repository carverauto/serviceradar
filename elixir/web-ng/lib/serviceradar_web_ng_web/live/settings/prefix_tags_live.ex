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
  # Snapshot-backed tabs list CNPG rows. External materializers only show trie stats.
  @snapshot_tabs ~w(manual netbox)
  @external_tabs ~w(provider ti dns-policy)
  @source_tabs @snapshot_tabs ++ @external_tabs
  # Page size under the streams iron-law threshold; offset paging for the rest.
  @list_limit 100

  @impl true
  def mount(_params, _session, socket) do
    # Disconnected mount: use cached scope only (no DB reauthorization).
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @permission) do
      {:ok,
       socket
       |> assign(:page_title, "Prefix Tags")
       |> assign(:current_path, @current_path)
       |> assign(:source_tab, "manual")
       |> assign(:source_tabs, @source_tabs)
       |> assign(:snapshot_backed?, true)
       |> assign(:tags, [])
       |> assign(:tag_count, 0)
       |> assign(:list_offset, 0)
       |> assign(:list_truncated?, false)
       |> assign(:has_prev_page?, false)
       |> assign(:has_next_page?, false)
       |> assign(:form_mode, nil)
       |> assign(:editing, nil)
       |> assign(:form, empty_form())
       |> assign(:preview_ip, "")
       |> assign(:preview_chain, nil)
       |> assign(:preview_error, nil)
       |> assign(:store_stats, %{})
       |> assign(:sources_label, "—")
       |> assign(:external_source_stats, nil)
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
    offset = parse_offset(Map.get(params, "offset"))

    socket =
      socket
      |> assign(:source_tab, tab)
      |> assign(:snapshot_backed?, tab in @snapshot_tabs)
      |> assign(:list_offset, offset)
      |> assign(:form_mode, nil)
      |> assign(:editing, nil)
      |> assign(:form, empty_form())

    if connected?(socket) do
      case authorize_socket(socket) do
        {:ok, socket} -> {:noreply, reload_tags(socket)}
        {:noreply, socket} -> {:noreply, socket}
      end
    else
      {:noreply, assign(socket, :loading?, false)}
    end
  end

  @impl true
  def handle_event("select_source", %{"source" => source}, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        {:noreply,
         push_patch(socket,
           to: ~p"/settings/networks/prefix-tags?source=#{normalize_tab(source)}"
         )}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("page", %{"dir" => dir}, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        offset = socket.assigns.list_offset
        next = if dir == "prev", do: max(offset - @list_limit, 0), else: offset + @list_limit
        tab = socket.assigns.source_tab

        {:noreply,
         push_patch(socket,
           to: ~p"/settings/networks/prefix-tags?source=#{tab}&offset=#{next}"
         )}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("new", _params, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        if socket.assigns.source_tab == "manual" do
          {:noreply,
           socket
           |> assign(:form_mode, :new)
           |> assign(:editing, nil)
           |> assign(:form, empty_form())}
        else
          {:noreply, put_flash(socket, :error, "Only the manual source is editable")}
        end

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        case fetch_tag(socket, id) do
          {:ok, %PrefixTag{} = tag} ->
            if manual_tag?(tag) do
              {:noreply,
               socket
               |> assign(:form_mode, :edit)
               |> assign(:editing, tag)
               |> assign(:form, tag_to_form(tag))}
            else
              {:noreply, put_flash(socket, :error, "Imported tags are read-only")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Tag not found")}
        end

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        {:noreply,
         socket
         |> assign(:form_mode, nil)
         |> assign(:editing, nil)
         |> assign(:form, empty_form())}

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("save", %{"prefix_tag" => params}, socket) do
    case authorize_socket(socket) do
      {:ok, socket} -> do_save(socket, params)
      {:noreply, socket} -> {:noreply, socket}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        case fetch_tag(socket, id) do
          {:ok, tag} ->
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

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Tag not found")}
        end

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("preview", params, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
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

      {:noreply, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("reload_trie", _params, socket) do
    case authorize_socket(socket) do
      {:ok, socket} ->
        case ServiceRadar.PrefixTags.Loader.reload() do
          :ok ->
            {:noreply,
             socket
             |> assign(:store_stats, Store.stats())
             |> reload_tags()
             |> put_flash(:info, "Prefix-tag tries reloaded on this node (all sources)")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:store_stats, Store.stats())
             |> put_flash(:error, "Reload failed: #{inspect(reason)}")}
        end

      {:noreply, socket} ->
        {:noreply, socket}
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
              <h1 class="text-2xl font-semibold text-sr-ink">Prefix Tags</h1>
              <p class="text-sm text-sr-muted mt-1 max-w-2xl">
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
                <div class="text-xs uppercase text-sr-muted">IPv4</div>
                <div>{Map.get(@store_stats, :ipv4_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-sr-muted">IPv6</div>
                <div>{Map.get(@store_stats, :ipv6_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-sr-muted">Total</div>
                <div>{Map.get(@store_stats, :total_prefixes, 0)}</div>
              </div>
              <div>
                <div class="text-xs uppercase text-sr-muted">Sources</div>
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
                <label class="text-xs uppercase tracking-wider text-sr-muted">
                  IP address
                </label>
                <input
                  type="text"
                  name="ip"
                  value={@preview_ip}
                  placeholder="10.1.2.3"
                  class={ui_field_class(size: "sm", mono: true, class: "w-full")}
                  autocomplete="off"
                />
              </div>
              <.ui_button type="submit" size="sm" variant="primary">Preview</.ui_button>
            </form>
            <div
              :if={@preview_error}
              class={ui_alert_class(variant: "warning", class: "mt-3 text-sm")}
            >
              {@preview_error}
            </div>
            <div :if={is_list(@preview_chain)} class="mt-3 space-y-2">
              <%= if @preview_chain == [] do %>
                <p class="text-sm text-sr-muted">No matching prefixes for this address.</p>
              <% else %>
                <div
                  :for={match <- @preview_chain}
                  class="rounded-lg border border-sr-line bg-sr-subtle/30 p-2"
                >
                  <div class="font-mono text-xs text-sr-muted">
                    {Map.get(match, :prefix) || "—"}
                    <.ui_badge
                      :if={src = Map.get(match, :source)}
                      size="xs"
                      variant="ghost"
                      class="ml-2"
                    >
                      {src}
                    </.ui_badge>
                  </div>
                  <div class="mt-1 flex flex-wrap gap-1">
                    <.ui_badge
                      :for={tag <- List.wrap(Map.get(match, :tags) || [])}
                      size="xs"
                      variant="outline"
                      class="font-mono"
                    >
                      {tag}
                    </.ui_badge>
                  </div>
                </div>
              <% end %>
            </div>
          </.ui_panel>

          <div class="sr-ui-tabs sr-ui-tabs-boxed bg-sr-subtle/40 p-1 w-fit flex-wrap">
            <button
              :for={tab <- @source_tabs}
              type="button"
              phx-click="select_source"
              phx-value-source={tab}
              class={["sr-ui-tab", @source_tab == tab && "sr-ui-tab-active"]}
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
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Prefix (CIDR)</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[prefix]"
                    value={@form["prefix"]}
                    required
                    placeholder="10.1.2.0/24"
                    class={ui_field_class(size: "sm", mono: true)}
                  />
                </div>
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">VRF (optional)</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[vrf]"
                    value={@form["vrf"]}
                    class={ui_field_class(size: "sm", mono: true)}
                  />
                </div>
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Site</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[site]"
                    value={@form["site"]}
                    placeholder="hq"
                    class={ui_field_class(size: "sm")}
                  />
                </div>
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Role</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[role]"
                    value={@form["role"]}
                    placeholder="wifi"
                    class={ui_field_class(size: "sm")}
                  />
                </div>
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Tenant</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[tenant]"
                    value={@form["tenant"]}
                    class={ui_field_class(size: "sm")}
                  />
                </div>
                <div class="flex flex-col gap-1.5">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Status</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[status]"
                    value={@form["status"]}
                    placeholder="active"
                    class={ui_field_class(size: "sm")}
                  />
                </div>
                <div class="flex flex-col gap-1.5 sm:col-span-2">
                  <label class="flex items-center justify-between gap-2">
                    <span class="text-sm font-medium text-sr-ink">Extra tags (optional)</span>
                  </label>
                  <input
                    type="text"
                    name="prefix_tag[tags]"
                    value={@form["tags"]}
                    placeholder="zone:dmz env:prod"
                    class={ui_field_class(size: "sm", mono: true)}
                  />
                  <p class="text-xs text-sr-muted">
                    Site, role, tenant, and status become tags automatically
                    (<span class="font-mono">site:hq</span>, <span class="font-mono">role:wifi</span>, …). Use this box only for
                    additional tags. Fill at least one structured field or one extra tag.
                    See
                    <a
                      href="https://docs.serviceradar.cloud/docs/prefix-tags"
                      class="link link-hover"
                      target="_blank"
                      rel="noopener"
                    >
                      Prefix Tags
                    </a>
                    .
                  </p>
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
                  {@source_tab}
                  <span :if={@snapshot_backed?} class="font-normal text-sr-muted">
                    ({@tag_count}{if @list_truncated?, do: "+", else: ""})
                  </span>
                </div>
                <div
                  :if={@source_tab != "manual"}
                  class="text-xs text-sr-muted"
                >
                  {if @snapshot_backed?,
                    do: "Read-only imported source",
                    else: "In-memory materializer (no CNPG prefix_tags rows)"}
                </div>
              </div>
            </:header>

            <div :if={@loading?} class="py-8 text-center text-sm text-sr-muted">
              Loading…
            </div>

            <div
              :if={not @loading? and not @snapshot_backed? and is_map(@external_source_stats)}
              class="space-y-2 text-sm"
            >
              <p class="text-sr-muted">
                This source is compiled into the local LPM trie from its platform
                table (not <code class="font-mono text-xs">platform.prefix_tags</code>).
                Use IP preview above to exercise lookups.
              </p>
              <div class="grid grid-cols-3 gap-3 font-mono text-xs">
                <div>
                  <div class="uppercase text-sr-muted">IPv4</div>
                  <div>{Map.get(@external_source_stats, :ipv4_prefixes, 0)}</div>
                </div>
                <div>
                  <div class="uppercase text-sr-muted">IPv6</div>
                  <div>{Map.get(@external_source_stats, :ipv6_prefixes, 0)}</div>
                </div>
                <div>
                  <div class="uppercase text-sr-muted">Total</div>
                  <div>{Map.get(@external_source_stats, :total_prefixes, 0)}</div>
                </div>
              </div>
            </div>

            <div
              :if={not @loading? and @snapshot_backed? and @tags == []}
              class="py-8 text-center text-sm text-sr-muted"
            >
              No prefixes for this source yet.
              <span :if={@source_tab == "manual"}>Use “Add prefix” to create one.</span>
            </div>

            <div
              :if={not @loading? and @snapshot_backed? and (@has_prev_page? or @has_next_page?)}
              class="mb-2 flex items-center justify-between text-xs text-sr-muted"
            >
              <span>
                Showing {@list_offset + 1}–{@list_offset + @tag_count}
                <span :if={@has_next_page?}> (more available)</span>
              </span>
              <div class="flex gap-2">
                <.ui_button
                  :if={@has_prev_page?}
                  size="xs"
                  variant="ghost"
                  phx-click="page"
                  phx-value-dir="prev"
                >
                  Previous
                </.ui_button>
                <.ui_button
                  :if={@has_next_page?}
                  size="xs"
                  variant="ghost"
                  phx-click="page"
                  phx-value-dir="next"
                >
                  Next
                </.ui_button>
              </div>
            </div>

            <div :if={not @loading? and @snapshot_backed? and @tags != []} class="overflow-x-auto">
              <table class={ui_table_class(size: "sm", zebra: true, class: "w-full")}>
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
                        <.ui_badge
                          :for={t <- List.wrap(tag.tags)}
                          size="xs"
                          variant="outline"
                          class="font-mono"
                        >
                          {t}
                        </.ui_badge>
                      </div>
                    </td>
                    <td class="text-xs text-sr-muted">
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

  # Always returns a valid LiveView tuple shape for handle_event/handle_params.
  defp authorize_socket(socket) do
    case RBAC.authorize_current(socket.assigns.current_scope, [@permission]) do
      {:ok, scope} ->
        {:ok, assign(socket, :current_scope, scope)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Not authorized")
         |> redirect(to: ~p"/settings/profile")}
    end
  end

  defp fetch_tag(socket, id) do
    scope = socket.assigns.current_scope

    case Enum.find(socket.assigns.tags, &(to_string(&1.id) == to_string(id))) do
      %PrefixTag{} = tag ->
        {:ok, tag}

      nil ->
        Manual.get(id, scope: scope)
    end
  end

  defp parse_offset(nil), do: 0
  defp parse_offset(""), do: 0

  defp parse_offset(raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp reload_tags(socket) do
    scope = socket.assigns.current_scope
    source = socket.assigns.source_tab
    offset = socket.assigns[:list_offset] || 0
    stats = Store.stats()

    sources_label =
      case stats do
        %{sources: %{} = sources} ->
          keys = sources |> Map.keys() |> Enum.sort()
          if keys == [], do: "—", else: Enum.join(keys, ", ")

        _ ->
          "—"
      end

    socket =
      socket
      |> assign(:store_stats, stats)
      |> assign(:sources_label, sources_label)
      |> assign(:loading?, false)

    if source in @snapshot_tabs do
      {tags, has_next?} =
        case Manual.list(source: source, scope: scope, limit: @list_limit + 1, offset: offset) do
          {:ok, list} when length(list) > @list_limit ->
            {Enum.take(list, @list_limit), true}

          {:ok, list} ->
            {list, false}

          {:error, _} ->
            {[], false}
        end

      socket
      |> assign(:tags, tags)
      |> assign(:tag_count, length(tags))
      |> assign(:list_truncated?, has_next? or offset > 0)
      |> assign(:has_prev_page?, offset > 0)
      |> assign(:has_next_page?, has_next?)
      |> assign(:list_limit, @list_limit)
      |> assign(:external_source_stats, nil)
      |> assign(:snapshot_backed?, true)
    else
      socket
      |> assign(:tags, [])
      |> assign(:tag_count, 0)
      |> assign(:list_truncated?, false)
      |> assign(:has_prev_page?, false)
      |> assign(:has_next_page?, false)
      |> assign(:list_limit, @list_limit)
      |> assign(:external_source_stats, Store.stats(source))
      |> assign(:snapshot_backed?, false)
    end
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
    extra_tags =
      tag.tags
      |> List.wrap()
      |> Enum.reject(&structured_tag?/1)
      |> Enum.join(" ")

    %{
      "prefix" => to_string(tag.prefix || ""),
      "vrf" => tag.vrf || "",
      "tags" => extra_tags,
      "site" => tag.site || "",
      "role" => tag.role || "",
      "tenant" => tag.tenant || "",
      "status" => tag.status || ""
    }
  end

  defp structured_tag?(tag) when is_binary(tag) do
    case String.split(tag, ":", parts: 2) do
      [key, _] -> key in ~w(site role tenant status)
      _ -> false
    end
  end

  defp structured_tag?(_), do: false

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

  defp format_error(:tags_required) do
    "Add at least one tag, or fill site, role, tenant, or status."
  end

  defp format_error(:tags_invalid), do: "Tags are invalid."
  defp format_error(:tag_empty), do: "Tags cannot include an empty value."
  defp format_error(:tag_too_long), do: "A tag is longer than the allowed length."
  defp format_error({:tag_invalid_chars, tag}), do: "Tag #{tag} has invalid characters."

  defp format_error(%Ash.Error.Invalid{errors: errors}) do
    Enum.map_join(errors, "; ", fn
      %{message: msg} when is_binary(msg) -> msg
      other -> inspect(other)
    end)
  end

  defp format_error(other), do: inspect(other)
end
