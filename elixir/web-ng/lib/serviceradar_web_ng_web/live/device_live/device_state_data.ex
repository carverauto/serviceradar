defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceStateData do
  @moduledoc false

  use ServiceRadarWebNGWeb, :verified_routes

  alias ServiceRadar.Repo

  require Logger

  # Virtual keys injected into device rows by tag_agent_device/2. They are not
  # OCSF columns; the OCSF `agent_list` column stays untouched for payload
  # compatibility but is never consulted for badge logic (nothing writes it).
  @agent_flag_key "agent_device"
  @agent_labels_key "agent_labels"

  def ansible_managed?(%{ansible_managed: true}), do: true
  def ansible_managed?(%{"ansible_managed" => true}), do: true
  def ansible_managed?(_), do: false

  def deleted?(row) when is_map(row) do
    value = Map.get(row, "deleted_at")
    not is_nil(value) and value != ""
  end

  def deleted?(_), do: false

  @doc """
  Render-time agent predicate. Reads the agent flag injected at load time by
  `tag_agent_device/2`; use `agent_device?/1` when you need to resolve the
  linkage directly from the database.
  """
  def agent?(row) when is_map(row) do
    Map.get(row, @agent_flag_key, Map.get(row, :agent_device)) == true
  end

  def agent?(_), do: false

  @doc """
  Render-time accessor for the agent labels injected by `tag_agent_device/2`.
  """
  def agent_labels(row) when is_map(row) do
    case Map.get(row, @agent_labels_key, Map.get(row, :agent_labels)) do
      labels when is_list(labels) -> Enum.filter(labels, &present_text?/1)
      _ -> []
    end
  end

  def agent_labels(_), do: []

  @doc """
  Answers whether a device hosts a registered agent via the
  `platform.ocsf_agents` `device_uid` linkage. Accepts a device UID or a
  device row (single query either way).
  """
  def agent_device?(device_uid) when is_binary(device_uid) do
    [device_uid]
    |> agent_directory()
    |> Map.has_key?(device_uid)
  end

  def agent_device?(row) when is_map(row) do
    case row_device_uid(row) do
      nil -> false
      device_uid -> agent_device?(device_uid)
    end
  end

  def agent_device?(_), do: false

  @doc """
  Batch variant for list views: returns the subset of `device_uids` that have
  at least one registered agent, as a `MapSet`.
  """
  def agent_device_uids(device_uids) when is_list(device_uids) do
    device_uids
    |> agent_directory()
    |> Map.keys()
    |> MapSet.new()
  end

  def agent_device_uids(_), do: MapSet.new()

  @doc """
  Maps each linked device UID to the labels (agent name or uid) of its
  registered agents in `platform.ocsf_agents`. UIDs without a registered
  agent are absent from the result.
  """
  def agent_directory(device_uids) when is_list(device_uids) do
    uids =
      device_uids
      |> Enum.filter(&present_text?/1)
      |> Enum.uniq()

    if uids == [] do
      %{}
    else
      case Repo.query(
             """
             SELECT device_uid, COALESCE(NULLIF(name, ''), uid) AS label
             FROM platform.ocsf_agents
             WHERE device_uid = ANY($1::text[])
             ORDER BY device_uid, label
             """,
             [uids]
           ) do
        {:ok, %{rows: rows}} ->
          Enum.reduce(rows, %{}, fn
            [device_uid, label], acc when is_binary(device_uid) ->
              Map.update(acc, device_uid, List.wrap(label), &(&1 ++ List.wrap(label)))

            _row, acc ->
              acc
          end)

        {:error, reason} ->
          Logger.warning("Failed to load agent device linkage: #{inspect(reason)}")
          %{}
      end
    end
  rescue
    error ->
      Logger.warning("Failed to load agent device linkage: #{inspect(error)}")
      %{}
  end

  def agent_directory(_), do: %{}

  @doc """
  Resolves the agent linkage for `device_uid` once and tags every device row
  in `results` so render-time predicates (`agent?/1`, `agent_labels/1`)
  answer without re-querying.
  """
  def tag_agent_device(results, device_uid) when is_list(results) and is_binary(device_uid) do
    directory = agent_directory([device_uid])
    flag = Map.has_key?(directory, device_uid)
    labels = Map.get(directory, device_uid, [])

    Enum.map(results, fn
      row when is_map(row) ->
        row
        |> Map.put(@agent_flag_key, flag)
        |> Map.put(@agent_labels_key, labels)

      other ->
        other
    end)
  end

  def tag_agent_device(results, _device_uid), do: results

  def display_name(nil), do: "Device"

  def display_name(row) when is_map(row) do
    hostname = Map.get(row, "hostname")
    ip = Map.get(row, "ip")

    cond do
      is_binary(hostname) and hostname != "" -> hostname
      is_binary(ip) and ip != "" -> ip
      # Fall back to the device uid so the breadcrumb / header reads the device's
      # identity instead of the literal "Device" when hostname and IP are absent.
      true -> row_device_uid(row) || "Device"
    end
  end

  def display_name(_), do: "Device"

  def proxmox_console_target?(%{kind: :host, host: %{provider: "proxmox"}}), do: true
  def proxmox_console_target?(%{kind: :guest, guest: %{provider: "proxmox"}}), do: true
  def proxmox_console_target?(_summary), do: false

  def proxmox_console_action_label(%{kind: :host}), do: "Open PVE shell"
  def proxmox_console_action_label(_summary), do: "Open console"

  def proxmox_console_path(device_uid, %{kind: :host}) do
    ~p"/devices/#{device_uid}/proxmox-console"
  end

  def proxmox_console_path(device_uid, _summary), do: ~p"/devices/#{device_uid}/proxmox-console"

  def deleted_by_from_scope(%{user: user}) when is_map(user) do
    Map.get(user, :email) || Map.get(user, :id)
  end

  def deleted_by_from_scope(_), do: nil

  defp row_device_uid(row) when is_map(row) do
    uid = Map.get(row, "uid") || Map.get(row, :uid) || Map.get(row, "id") || Map.get(row, :id)
    if present_text?(uid), do: uid
  end

  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""
end
