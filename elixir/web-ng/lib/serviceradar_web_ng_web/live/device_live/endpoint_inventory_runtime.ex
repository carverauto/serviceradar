defmodule ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryMatchGroups

  @cache_query_type "endpoint_inventory.cache_query"
  @force_fresh_type "endpoint_inventory.force_fresh_scan"
  @cohort_query_type "endpoint_inventory.cohort_cache_query"

  def assign_defaults(socket) do
    socket
    |> assign(
      :endpoint_inventory_query_form,
      to_form(default_query_params(), as: :endpoint_inventory_query)
    )
    |> assign(
      :endpoint_inventory_cohort_form,
      to_form(default_cohort_params(), as: :endpoint_inventory_cohort_query)
    )
    |> assign(
      :endpoint_inventory_package_filter_form,
      to_form(default_package_filter_params(), as: :endpoint_inventory_filter)
    )
    |> assign(:endpoint_inventory_live_query_result, nil)
    |> assign(:endpoint_inventory_cohort_query_result, nil)
    |> assign(:endpoint_inventory_command_notice, nil)
    |> assign(:endpoint_inventory_command_error, nil)
    |> assign(:endpoint_inventory_query_running, false)
    |> assign(:endpoint_inventory_force_refresh_running, false)
    |> assign(:endpoint_inventory_cohort_running, false)
    |> assign(:endpoint_inventory_pending_command_ids, MapSet.new())
    |> assign(:show_endpoint_inventory_package_modal, false)
    |> assign(:endpoint_inventory_selected_package, nil)
    |> assign(:endpoint_inventory_selected_package_assessment_details, empty_assessment_details())
    |> assign(:show_endpoint_inventory_match_modal, false)
    |> assign(:endpoint_inventory_selected_match_group, nil)
  end

  def dispatch_device_query(socket, params, opts \\ []) when is_map(params) do
    params = normalize_params(params)

    with {:ok, agent_id} <- selected_agent_id(socket, params),
         {:ok, payload} <- query_payload(params, "exists") do
      case command_bus(opts).dispatch_endpoint_inventory_cache_query(agent_id, payload,
             actor: actor(socket),
             context: device_command_context(socket),
             ttl_seconds: int_param(params, "ttl_seconds", 30)
           ) do
        {:ok, command_id} ->
          socket
          |> assign(
            :endpoint_inventory_query_form,
            to_form(params, as: :endpoint_inventory_query)
          )
          |> assign(:endpoint_inventory_query_running, true)
          |> assign(:endpoint_inventory_live_query_result, nil)
          |> assign(:endpoint_inventory_command_error, nil)
          |> assign(
            :endpoint_inventory_command_notice,
            "Inventory query dispatched to #{agent_id}"
          )
          |> track_pending_command(command_id)

        {:error, reason} ->
          put_command_error(
            socket,
            "Failed to dispatch inventory query: #{format_reason(reason)}"
          )
      end
    else
      {:error, reason} -> put_command_error(socket, format_reason(reason))
    end
  end

  def dispatch_force_refresh(socket, params, opts \\ []) when is_map(params) do
    params = normalize_params(params)

    with {:ok, agent_id} <- selected_agent_id(socket, params),
         {:ok, payload} <- force_refresh_payload(params) do
      case command_bus(opts).dispatch_endpoint_inventory_force_fresh_scan(agent_id, payload,
             actor: actor(socket),
             context: device_command_context(socket),
             ttl_seconds: int_param(params, "ttl_seconds", 120)
           ) do
        {:ok, command_id} ->
          socket
          |> assign(:endpoint_inventory_force_refresh_running, true)
          |> assign(:endpoint_inventory_command_error, nil)
          |> assign(
            :endpoint_inventory_command_notice,
            "Fresh inventory scan dispatched to #{agent_id}"
          )
          |> track_pending_command(command_id)

        {:error, reason} ->
          put_command_error(socket, "Failed to dispatch fresh scan: #{format_reason(reason)}")
      end
    else
      {:error, reason} -> put_command_error(socket, format_reason(reason))
    end
  end

  def dispatch_cohort_query(socket, params, opts \\ []) when is_map(params) do
    params = normalize_params(params)

    with {:ok, payload} <- query_payload(params, "count"),
         {:ok, agent_ids} <- cohort_agent_ids(params) do
      bus_opts =
        Keyword.merge(
          [
            actor: actor(socket),
            context: device_command_context(socket),
            partition_id: partition_id(socket),
            agent_ids: agent_ids,
            cohort_cap: int_param(params, "cohort_cap", 128),
            cohort_timeout_ms: int_param(params, "timeout_ms", 5_000)
          ],
          opts
        )

      case command_bus(opts).dispatch_endpoint_inventory_cohort_cache_query(payload, bus_opts) do
        {:ok, result} ->
          socket
          |> assign(
            :endpoint_inventory_cohort_form,
            to_form(params, as: :endpoint_inventory_cohort_query)
          )
          |> assign(:endpoint_inventory_cohort_running, false)
          |> assign(:endpoint_inventory_cohort_query_result, normalize_cohort_result(result))
          |> assign(:endpoint_inventory_command_error, nil)
          |> assign(:endpoint_inventory_command_notice, "Cohort inventory query completed")

        {:error, reason} ->
          put_command_error(socket, "Failed to run cohort query: #{format_reason(reason)}")
      end
    else
      {:error, reason} -> put_command_error(socket, format_reason(reason))
    end
  end

  def apply_command_update(socket, kind, msg) when kind in [:ack, :progress, :result] and is_map(msg) do
    command_type = map_get(msg, :command_type)

    if endpoint_inventory_command_type?(command_type) and relevant_command_update?(socket, msg) do
      socket
      |> apply_command_kind(kind, msg)
      |> untrack_if_result(kind, msg)
    else
      socket
    end
  end

  def apply_command_update(socket, _kind, _msg), do: socket

  def default_query_params do
    %{
      "agent_id" => "",
      "package_manager" => "",
      "name" => "",
      "version" => "",
      "purl_canonical" => "",
      "cpe" => "",
      "mode" => "exists",
      "limit" => "25",
      "ttl_seconds" => "30"
    }
  end

  def default_cohort_params do
    %{
      "cohort" => "connected",
      "agent_ids" => "",
      "package_manager" => "",
      "name" => "",
      "version" => "",
      "purl_canonical" => "",
      "cpe" => "",
      "mode" => "count",
      "limit" => "25",
      "timeout_ms" => "5000",
      "cohort_cap" => "128"
    }
  end

  def default_package_filter_params do
    %{
      "q" => "",
      "package_manager" => "",
      "version" => "",
      "purl" => "",
      "cpe" => ""
    }
  end

  @doc """
  Applies the package search/filter form. Filtering and pagination are handled
  server-side, so changing a filter re-queries the database and resets to the
  first page.
  """
  def apply_package_filter(socket, params) when is_map(params) do
    filter_params = Map.merge(default_package_filter_params(), package_filter_params(params))

    socket
    |> assign(
      :endpoint_inventory_package_filter_form,
      to_form(filter_params, as: :endpoint_inventory_filter)
    )
    |> assign(:endpoint_inventory_package_page, 1)
    |> reload_packages()
  end

  @doc """
  Moves the package list to the requested 1-based page and re-queries.
  """
  def change_package_page(socket, page) do
    socket
    |> assign(:endpoint_inventory_package_page, clamp_page(page, total_pages(socket)))
    |> reload_packages()
  end

  @doc """
  Opens the package-detail modal for the package row with the given id. The row is
  taken from the already-loaded page; its vulnerability matches are queried scoped
  to the device and the package's `endpoint_package_ref`.
  """
  def open_package_detail(socket, package_ref) when is_binary(package_ref) do
    packages = socket.assigns[:endpoint_inventory_packages] || []

    case Enum.find(packages, &(package_id(&1) == package_ref)) do
      nil ->
        socket

      package ->
        assessment_details =
          EndpointInventoryData.load_package_vulnerabilities(
            Map.get(socket.assigns, :current_scope),
            socket.assigns[:device_uid],
            endpoint_package_ref(package)
          )

        socket
        |> assign(:endpoint_inventory_selected_package, package)
        |> assign(:endpoint_inventory_selected_package_assessment_details, assessment_details)
        |> assign(:show_endpoint_inventory_package_modal, true)
    end
  end

  def open_package_detail(socket, _package_ref), do: socket

  @doc """
  Closes the package-detail modal and clears its selection.
  """
  def close_package_detail(socket) do
    socket
    |> assign(:show_endpoint_inventory_package_modal, false)
    |> assign(:endpoint_inventory_selected_package, nil)
    |> assign(:endpoint_inventory_selected_package_assessment_details, empty_assessment_details())
  end

  @doc """
  Opens the advisory-detail modal for a Vulnerability Matches row already loaded
  on the device Software tab. Loads the advisory relationship for description
  and reference URLs.
  """
  def open_match_detail(socket, group_id) when is_binary(group_id) do
    assessments = assessment_rows(socket.assigns[:endpoint_inventory_vulnerability_assessments])
    groups = EndpointInventoryMatchGroups.group(assessments)

    case EndpointInventoryMatchGroups.find(groups, group_id) do
      nil ->
        socket

      group ->
        scope = Map.get(socket.assigns, :current_scope)

        supporting_matches = EndpointInventoryData.load_supporting_matches(scope, group.assessments)

        selected_group =
          group.assessments
          |> EndpointInventoryMatchGroups.group(supporting_matches)
          |> List.first()

        socket
        |> assign(:endpoint_inventory_selected_match_group, selected_group)
        |> assign(:show_endpoint_inventory_match_modal, true)
    end
  end

  def open_match_detail(socket, _group_id), do: socket

  @doc """
  Closes the advisory-detail modal and clears its selection.
  """
  def close_match_detail(socket) do
    socket
    |> assign(:show_endpoint_inventory_match_modal, false)
    |> assign(:endpoint_inventory_selected_match_group, nil)
  end

  defp package_id(package) do
    package
    |> field(:id)
    |> to_string_or_nil()
  end

  defp endpoint_package_ref(package) do
    package
    |> field(:endpoint_package_ref)
    |> to_string_or_nil()
  end

  defp assessment_rows(%{} = pages) do
    Enum.flat_map([:confirmed, :candidates, :history], fn key ->
      pages
      |> Map.get(key, Map.get(pages, to_string(key), %{}))
      |> case do
        %{rows: rows} when is_list(rows) -> rows
        %{"rows" => rows} when is_list(rows) -> rows
        rows when is_list(rows) -> rows
        _ -> []
      end
    end)
  end

  defp assessment_rows(rows) when is_list(rows), do: rows
  defp assessment_rows(_pages), do: []

  defp empty_assessment_details do
    %{
      assessments: [],
      supporting_matches: [],
      supporting_matches_total: 0,
      supporting_matches_truncated?: false
    }
  end

  defp field(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, to_string(key))
  end

  defp field(_row, _key), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  defp reload_packages(socket) do
    scope = Map.get(socket.assigns, :current_scope)
    device_uid = socket.assigns[:device_uid]

    opts = [
      filters: package_filter_map(socket),
      page: socket.assigns[:endpoint_inventory_package_page] || 1,
      page_size:
        socket.assigns[:endpoint_inventory_package_page_size] ||
          EndpointInventoryData.default_page_size()
    ]

    case EndpointInventoryData.load_packages(scope, device_uid, opts) do
      {:ok, page} ->
        socket
        |> assign(:endpoint_inventory_packages, page.packages)
        |> assign(:endpoint_inventory_package_total, page.total)
        |> assign(:endpoint_inventory_package_page, page.page)
        |> assign(:endpoint_inventory_package_page_size, page.page_size)
        |> assign(:endpoint_inventory_stored_package_count, page.stored_package_count)

      :error ->
        socket
    end
  end

  defp package_filter_params(params) do
    params
    |> normalize_string_map()
    |> Map.take(["q", "package_manager", "version", "purl", "cpe"])
  end

  defp package_filter_map(socket) do
    form = socket.assigns[:endpoint_inventory_package_filter_form]
    params = if is_struct(form, Phoenix.HTML.Form), do: form.params || %{}, else: %{}

    %{
      q: Map.get(params, "q"),
      package_manager: Map.get(params, "package_manager"),
      version: Map.get(params, "version"),
      purl: Map.get(params, "purl"),
      cpe: Map.get(params, "cpe")
    }
  end

  defp total_pages(socket) do
    total = socket.assigns[:endpoint_inventory_package_total] || 0

    page_size =
      socket.assigns[:endpoint_inventory_package_page_size] ||
        EndpointInventoryData.default_page_size()

    max(1, ceil(total / max(page_size, 1)))
  end

  defp clamp_page(page, total_pages) when is_integer(page) do
    page |> max(1) |> min(total_pages)
  end

  defp clamp_page(page, total_pages) do
    case Integer.parse(to_string(page)) do
      {value, _} -> clamp_page(value, total_pages)
      :error -> 1
    end
  end

  defp normalize_string_map(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_string_map(_params), do: %{}

  defp apply_command_kind(socket, :ack, msg) do
    assign(
      socket,
      :endpoint_inventory_command_notice,
      command_message(msg, "Inventory command acknowledged")
    )
  end

  defp apply_command_kind(socket, :progress, msg) do
    assign(
      socket,
      :endpoint_inventory_command_notice,
      command_message(msg, "Inventory command running")
    )
  end

  defp apply_command_kind(socket, :result, msg) do
    payload = map_get(msg, :payload) || %{}
    success? = map_get(msg, :success) == true

    socket
    |> assign(:endpoint_inventory_query_running, false)
    |> assign(:endpoint_inventory_force_refresh_running, false)
    |> assign(:endpoint_inventory_live_query_result, payload)
    |> assign(
      :endpoint_inventory_command_notice,
      command_message(
        msg,
        if(success?, do: "Inventory command completed", else: "Inventory command failed")
      )
    )
    |> maybe_assign_result_error(success?, msg)
  end

  defp maybe_assign_result_error(socket, true, _msg), do: assign(socket, :endpoint_inventory_command_error, nil)

  defp maybe_assign_result_error(socket, false, msg) do
    assign(
      socket,
      :endpoint_inventory_command_error,
      map_get(msg, :failure_reason) || map_get(msg, :message) || "Inventory command failed"
    )
  end

  defp untrack_if_result(socket, :result, msg) do
    command_id = map_get(msg, :command_id)
    pending = Map.get(socket.assigns, :endpoint_inventory_pending_command_ids, MapSet.new())
    assign(socket, :endpoint_inventory_pending_command_ids, MapSet.delete(pending, command_id))
  end

  defp untrack_if_result(socket, _kind, _msg), do: socket

  defp query_payload(params, default_mode) do
    predicate = predicate_from_params(params)

    if predicate == %{} do
      {:error, "Choose at least one package coordinate"}
    else
      {:ok,
       %{
         mode: normalize_mode(Map.get(params, "mode"), default_mode),
         predicate: predicate,
         limit: int_param(params, "limit", 25),
         metadata: %{
           "source" => "web-ng-device-detail",
           "ui" => "endpoint_inventory"
         }
       }}
    end
  end

  defp force_refresh_payload(params) do
    query =
      case query_payload(params, "exists") do
        {:ok, payload} -> payload
        {:error, _} -> nil
      end

    {:ok,
     %{
       sources: ["os_packages"],
       query: query,
       metadata: %{
         "source" => "web-ng-device-detail",
         "ui" => "endpoint_inventory"
       }
     }}
  end

  defp predicate_from_params(params) do
    %{
      package_manager: clean(params["package_manager"]),
      name: clean(params["name"]),
      version: clean(params["version"]),
      purl_canonical: clean(params["purl_canonical"]),
      cpe: clean(params["cpe"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp selected_agent_id(socket, params) do
    [
      clean(params["agent_id"]),
      scan_field(socket.assigns[:endpoint_inventory_scan], :agent_id),
      device_field(socket.assigns[:device_row], "agent_id"),
      device_field(List.first(socket.assigns[:results] || []), "agent_id")
    ]
    |> Enum.find(&present?/1)
    |> case do
      nil -> {:error, "No endpoint inventory agent is available for this device"}
      agent_id -> {:ok, agent_id}
    end
  end

  defp cohort_agent_ids(%{"cohort" => "custom"} = params) do
    ids =
      params
      |> Map.get("agent_ids", "")
      |> String.split([",", "\n", "\r", "\t", " "], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if ids == [],
      do: {:error, "Choose at least one agent for the custom cohort"},
      else: {:ok, ids}
  end

  defp cohort_agent_ids(_params), do: {:ok, :all}

  defp normalize_cohort_result(result) when is_map(result) do
    %{
      query_id: map_get(result, :query_id),
      coverage: map_get(result, :coverage) || %{},
      results: map_get(result, :results) || [],
      dispatches: map_get(result, :dispatches) || []
    }
  end

  defp normalize_params(params) when is_map(params) do
    default_query_params()
    |> Map.merge(default_cohort_params())
    |> Map.merge(Map.new(params, fn {key, value} -> {to_string(key), value} end))
  end

  defp track_pending_command(socket, command_id) do
    pending = Map.get(socket.assigns, :endpoint_inventory_pending_command_ids, MapSet.new())

    assign(
      socket,
      :endpoint_inventory_pending_command_ids,
      MapSet.put(pending, to_string(command_id))
    )
  end

  defp relevant_command_update?(socket, msg) do
    command_id = map_get(msg, :command_id)
    pending = Map.get(socket.assigns, :endpoint_inventory_pending_command_ids, MapSet.new())
    context = map_get(msg, :context) || %{}
    payload = map_get(msg, :payload) || %{}

    MapSet.member?(pending, to_string(command_id)) or
      map_get(context, :device_uid) == socket.assigns[:device_uid] or
      map_get(payload, :device_uid) == socket.assigns[:device_uid]
  end

  defp endpoint_inventory_command_type?(@cache_query_type), do: true
  defp endpoint_inventory_command_type?(@force_fresh_type), do: true
  defp endpoint_inventory_command_type?(@cohort_query_type), do: true
  defp endpoint_inventory_command_type?(_), do: false

  defp put_command_error(socket, reason) do
    socket
    |> assign(:endpoint_inventory_query_running, false)
    |> assign(:endpoint_inventory_force_refresh_running, false)
    |> assign(:endpoint_inventory_cohort_running, false)
    |> assign(:endpoint_inventory_command_error, reason)
  end

  defp device_command_context(socket) do
    %{
      device_uid: socket.assigns[:device_uid],
      partition_id: partition_id(socket),
      source: "web-ng-device-detail"
    }
  end

  defp partition_id(socket), do: device_field(socket.assigns[:device_row], "partition_id") || "default"

  defp actor(socket), do: socket.assigns.current_scope.user

  defp command_bus(opts) do
    Keyword.get(opts, :command_bus) ||
      Application.get_env(:serviceradar_web_ng, :endpoint_inventory_command_bus, AgentCommandBus)
  end

  defp normalize_mode(mode, _default) when mode in ["exists", "count", "detail"], do: mode
  defp normalize_mode(_mode, default), do: default

  defp int_param(params, key, default) do
    case Integer.parse(to_string(Map.get(params, key, default))) do
      {value, _} when value > 0 -> value
      _ -> default
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp scan_field(nil, _field), do: nil
  defp scan_field(scan, field), do: Map.get(scan, field) || Map.get(scan, to_string(field))

  defp device_field(nil, _field), do: nil

  defp device_field(%{} = row, field) do
    Map.get(row, field) || Map.get(row, known_atom_field(field))
  end

  defp device_field(_row, _field), do: nil

  defp known_atom_field("agent_id"), do: :agent_id
  defp known_atom_field("partition_id"), do: :partition_id
  defp known_atom_field(_field), do: nil

  defp clean(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean(_value), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp command_message(msg, fallback), do: map_get(msg, :message) || fallback

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
