defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive.MembershipReview do
  @moduledoc """
  Memberships tab state for `ServiceRadarWebNGWeb.Settings.AnsibleLive`.

  Every read and the approval go through `ServiceRadarWebNG.AnsibleAutomation`
  with the session user's scope, the same entry points the
  `/api/admin/ansible-memberships` routes use. The caller re-checks
  `ansible.controllers.manage` before invoking any function here; the domain
  approval service re-checks the human principal and current authority from
  storage on its own.

  Approval submits the evidence tuple held in `:reviewing_membership`, which is
  exactly what the review panel rendered. A proposal that changed in between is
  rejected by the domain, reloaded, and shown again; it is never re-submitted.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream: 4, stream_configure: 3]

  alias ServiceRadarWebNG.AnsibleAutomation
  alias ServiceRadarWebNG.RBAC

  @view_permission "ansible.runs.view"
  @filters ~w(all needs_review approved not_linkable)
  @stale_reasons [
    :membership_identity_changed,
    :membership_evidence_changed,
    :membership_not_current,
    :membership_not_proposed,
    :membership_link_ambiguous,
    :membership_not_found
  ]

  @doc "Initial, inert tab state. Safe for the disconnected mount."
  def init(socket) do
    socket
    |> assign(:membership_controller_id, nil)
    |> assign(:membership_inventories, [])
    |> assign(:membership_inventory_id, nil)
    |> assign(:membership_filter, "all")
    |> assign(:membership_counts, counts([]))
    |> assign(:membership_notice, nil)
    |> assign(:reviewing_membership, nil)
    |> stream_configure(:memberships, dom_id: &"ansible-membership-#{&1.id}")
    |> stream(:memberships, [], reset: true)
  end

  @doc "Loads the tab for the given controllers, keeping the current selection when valid."
  def activate(socket, controllers) do
    controller_id = keep_or_first(socket.assigns.membership_controller_id, controllers)

    socket
    |> assign(:membership_controller_id, controller_id)
    |> assign(:reviewing_membership, nil)
    |> load_inventories()
    |> load_memberships()
  end

  @doc "Applies a controller/inventory selection from the scope form."
  def select_scope(socket, params, controllers) do
    requested_controller = Map.get(params, "controller_id")

    if requested_controller == socket.assigns.membership_controller_id do
      socket
      |> assign(:membership_inventory_id, known_inventory(socket, params["inventory_id"]))
      |> assign(:reviewing_membership, nil)
      |> load_memberships()
    else
      socket
      |> assign(:membership_controller_id, keep_or_first(requested_controller, controllers))
      |> assign(:membership_inventory_id, nil)
      |> assign(:reviewing_membership, nil)
      |> load_inventories()
      |> load_memberships()
    end
  end

  @doc "Switches the row filter and re-streams the current inventory."
  def filter(socket, filter) when filter in @filters do
    socket
    |> assign(:membership_filter, filter)
    |> load_memberships()
  end

  def filter(socket, _filter), do: socket

  @doc """
  Opens the review panel for one membership from freshly loaded evidence.

  The panel shows the current proposal, not the possibly older table row, and
  approval submits exactly what the panel shows.
  """
  def review(socket, id) do
    case fetch_memberships(socket) do
      {:ok, memberships} ->
        socket = put_memberships(socket, memberships)

        case Enum.find(memberships, &(to_string(&1.id) == id)) do
          nil ->
            socket
            |> assign(:reviewing_membership, nil)
            |> put_flash(:error, "That membership is no longer current in this inventory.")

          membership ->
            open_review(socket, membership)
        end

      {:error, socket} ->
        socket
    end
  end

  def cancel_review(socket), do: assign(socket, :reviewing_membership, nil)

  @doc "Approves the membership in the open review panel as the logged-in user."
  def approve(%{assigns: %{reviewing_membership: nil}} = socket) do
    put_flash(socket, :error, "Open a membership review before approving it.")
  end

  def approve(%{assigns: %{reviewing_membership: membership}} = socket) do
    scope = socket.assigns.current_scope

    case automation().approve_membership(scope, membership.id, approval_request(membership)) do
      {:ok, approved} ->
        socket
        |> assign(:reviewing_membership, nil)
        |> put_flash(
          :info,
          "Approved #{display(approved[:host_name])} -> #{display(approved[:canonical_device_uid])}."
        )
        |> load_inventories()
        |> load_memberships()

      {:error, reason} when reason in @stale_reasons ->
        socket
        |> assign(:reviewing_membership, nil)
        |> load_inventories()
        |> reopen_after_change(membership.id)

      {:error, :current_permission_denied} ->
        socket
        |> assign(:reviewing_membership, nil)
        |> put_flash(
          :error,
          "Approval was refused: your account no longer holds ansible.controllers.manage."
        )

      {:error, :human_approval_required} ->
        put_flash(socket, :error, "Approval requires a logged-in human user.")

      {:error, reason} ->
        put_flash(socket, :error, "Approval was rejected: #{format_reason(reason)}.")
    end
  end

  @doc "The exact request body the API approval route accepts, built from the shown tuple."
  def approval_request(membership) do
    %{
      "controller_id" => to_string(membership.controller_id),
      "inventory_id" => membership.inventory_id,
      "awx_host_id" => membership.awx_host_id,
      "canonical_device_uid" => membership.canonical_device_uid,
      "source_generation" => membership.source_generation,
      "source_fingerprint" => membership.source_fingerprint,
      "link_evidence_digest" => membership.link_evidence_digest
    }
  end

  ## Display helpers ---------------------------------------------------------

  @doc "True when the membership is a current, unambiguous proposal the domain can approve."
  def approvable?(membership) do
    is_nil(blocked_reason(membership))
  end

  @doc "Why a membership cannot be approved, or nil when it can."
  def blocked_reason(membership) do
    case membership.link_disposition do
      :approved ->
        "Already approved."

      :unlinked ->
        "No ServiceRadar device matches this AWX host. Correct its address or MAC in AWX " <>
          "and let discovery run; a link cannot be forced."

      :quarantined ->
        quarantine_reason(membership)

      :proposed ->
        proposal_blocked_reason(membership)

      other ->
        "Disposition #{display(other)} cannot be approved."
    end
  end

  def evidence_kind(membership), do: evidence(membership, "kind")
  def match_count(membership), do: evidence(membership, "match_count")

  def disposition_variant(:approved), do: "success"
  def disposition_variant(:proposed), do: "warning"
  def disposition_variant(:quarantined), do: "error"
  def disposition_variant(_), do: "ghost"

  def needs_review?(membership), do: membership.link_disposition == :proposed and membership.enabled == true

  ## Loading -----------------------------------------------------------------

  defp open_review(socket, membership) do
    if approvable?(membership) do
      assign(socket, :reviewing_membership, membership)
    else
      socket
      |> assign(:reviewing_membership, nil)
      |> put_flash(:error, "This membership cannot be approved. #{blocked_reason(membership)}")
    end
  end

  defp reopen_after_change(socket, id) do
    message =
      "The proposal changed after you reviewed it, so it was not approved. " <>
        "Review the current evidence below before approving again."

    case fetch_memberships(socket) do
      {:ok, memberships} ->
        socket = put_memberships(socket, memberships)

        case Enum.find(memberships, &(to_string(&1.id) == to_string(id))) do
          nil ->
            put_flash(
              socket,
              :error,
              "The proposal changed after you reviewed it and is no longer current."
            )

          membership ->
            if approvable?(membership) do
              socket
              |> assign(:reviewing_membership, membership)
              |> put_flash(:error, message)
            else
              put_flash(
                socket,
                :error,
                "The proposal changed after you reviewed it and can no longer be approved. " <>
                  blocked_reason(membership)
              )
            end
        end

      {:error, socket} ->
        socket
    end
  end

  defp load_inventories(%{assigns: %{membership_controller_id: nil}} = socket) do
    socket
    |> assign(:membership_inventories, [])
    |> assign(:membership_inventory_id, nil)
  end

  defp load_inventories(socket) do
    scope = socket.assigns.current_scope

    if RBAC.can?(scope, @view_permission) do
      case automation().list_membership_inventories(scope, socket.assigns.membership_controller_id) do
        {:ok, inventories} ->
          socket
          |> assign(:membership_notice, nil)
          |> assign(:membership_inventories, inventories)
          |> assign(
            :membership_inventory_id,
            default_inventory(socket.assigns.membership_inventory_id, inventories)
          )

        {:error, reason} ->
          socket
          |> assign(:membership_inventories, [])
          |> assign(:membership_inventory_id, nil)
          |> assign(:membership_notice, "Could not list inventories: #{format_reason(reason)}.")
      end
    else
      socket
      |> assign(:membership_inventories, [])
      |> assign(:membership_inventory_id, nil)
      |> assign(:membership_notice, "Listing memberships requires the #{@view_permission} permission.")
    end
  end

  defp load_memberships(socket) do
    case fetch_memberships(socket) do
      {:ok, memberships} -> put_memberships(socket, memberships)
      {:error, socket} -> socket
    end
  end

  defp fetch_memberships(%{assigns: %{membership_inventory_id: nil}} = socket) do
    {:error, put_memberships(socket, [])}
  end

  defp fetch_memberships(socket) do
    request = %{
      "controller_id" => socket.assigns.membership_controller_id,
      "inventory_id" => socket.assigns.membership_inventory_id
    }

    case automation().list_memberships(socket.assigns.current_scope, request) do
      {:ok, memberships} ->
        {:ok, memberships}

      {:error, reason} ->
        {:error,
         socket
         |> put_memberships([])
         |> assign(:membership_notice, "Could not list memberships: #{format_reason(reason)}.")}
    end
  end

  defp put_memberships(socket, memberships) do
    visible = Enum.filter(memberships, &visible?(&1, socket.assigns.membership_filter))

    socket
    |> assign(:membership_counts, counts(memberships))
    |> stream(:memberships, visible, reset: true)
  end

  defp counts(memberships) do
    %{
      all: length(memberships),
      needs_review: Enum.count(memberships, &needs_review?/1),
      approved: Enum.count(memberships, &(&1.link_disposition == :approved)),
      not_linkable: Enum.count(memberships, &(&1.link_disposition in [:unlinked, :quarantined]))
    }
  end

  defp visible?(_membership, "all"), do: true
  defp visible?(membership, "needs_review"), do: needs_review?(membership)
  defp visible?(membership, "approved"), do: membership.link_disposition == :approved

  defp visible?(membership, "not_linkable"), do: membership.link_disposition in [:unlinked, :quarantined]

  defp keep_or_first(requested, controllers) do
    ids = Enum.map(controllers, &to_string(&1.id))

    cond do
      is_binary(requested) and requested in ids -> requested
      ids == [] -> nil
      true -> hd(ids)
    end
  end

  defp known_inventory(socket, value) do
    known = Enum.map(socket.assigns.membership_inventories, & &1.inventory_id)

    case Integer.parse(to_string(value)) do
      {id, ""} -> if id in known, do: id, else: socket.assigns.membership_inventory_id
      _ -> socket.assigns.membership_inventory_id
    end
  end

  defp default_inventory(current, inventories) do
    ids = Enum.map(inventories, & &1.inventory_id)

    cond do
      current in ids -> current
      needing = Enum.find(inventories, &(&1.needs_review > 0)) -> needing.inventory_id
      ids == [] -> nil
      true -> hd(ids)
    end
  end

  defp quarantine_reason(membership) do
    case match_count(membership) do
      count when is_integer(count) and count > 1 ->
        "Ambiguous: #{count} devices match this AWX host, so it is quarantined. " <>
          "Resolve the duplicate devices; a link cannot be forced."

      _ ->
        "Quarantined. It cannot be approved or force-linked here."
    end
  end

  defp proposal_blocked_reason(membership) do
    cond do
      membership.enabled != true ->
        "The host is disabled in AWX."

      match_count(membership) != 1 or evidence_kind(membership) != "stored_awx_source_tuple" ->
        "The link evidence is not a single unambiguous match."

      not is_binary(membership.link_evidence_digest) ->
        "The link evidence digest is unavailable."

      not is_binary(membership.canonical_device_uid) ->
        "No device is proposed."

      true ->
        nil
    end
  end

  defp evidence(membership, key) do
    Map.get(Map.get(membership, :link_evidence) || %{}, key)
  end

  defp format_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
  defp format_reason(%Ash.Error.Forbidden{}), do: "permission denied"
  defp format_reason(_reason), do: "request rejected"

  defp display(nil), do: "-"
  defp display(value), do: to_string(value)

  defp automation, do: Application.get_env(:serviceradar_web_ng, :ansible_automation, AnsibleAutomation)
end
