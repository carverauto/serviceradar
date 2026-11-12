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
  exactly what the review dialog rendered. A proposal that changed in between is
  rejected by the domain, reloaded, and shown again; it is never re-submitted.

  Bulk approval keeps the same guarantee per membership. The selected IDs live
  in `:membership_selected` and are bounded by the approvable rows the current
  view lists. Opening the bulk dialog reloads current evidence and holds each
  shown row in `:membership_bulk`; confirming calls `approve_membership/3` once
  per row with that row's own tuple, off the LiveView process, and the result
  arrives through `bulk_approved/2`. A row whose evidence changed stays selected
  and is shown again with its fresh evidence; nothing is re-submitted on its
  own.

  Releasing a membership quarantine follows the same rule. The release dialog
  holds the freshly loaded row in `:releasing_membership` and submits exactly
  its evidence through `release_membership/3`. The domain re-checks current
  device inventory: one match makes the row `proposed` (it then needs the
  normal Review and approval, which this page never chains on its own), no
  match makes it `unlinked`, several matches refuse and the dialog lists them.
  Evidence that changed in between is shown again and needs another explicit
  confirmation.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [put_flash: 3, start_async: 3, stream: 4, stream_configure: 3, stream_insert: 3]

  alias ServiceRadarWebNG.AnsibleAutomation
  alias ServiceRadarWebNG.RBAC

  @view_permission "ansible.runs.view"
  @filters ~w(all needs_review approved quarantined unlinked)
  @release_stale_reasons [:membership_identity_changed, :membership_evidence_changed]
  @release_gone_reasons [:membership_not_quarantined, :membership_not_current, :membership_not_found]
  @quarantine_reason_labels %{
    ambiguous_device_match: "More than one ServiceRadar device matched this AWX host.",
    approved_device_changed: "The approved link started matching a different device.",
    approved_link_lost_match: "The approved link stopped matching any device.",
    approved_membership_not_current:
      "The approved host dropped out of a complete inventory sync and was seen again; " <>
        "its approval does not carry across the gap.",
    canonical_device_deleted: "The approved link's device was deleted from ServiceRadar.",
    predates_reason_recording: "Cause unknown: this host was quarantined before ServiceRadar recorded reasons."
  }
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
    |> assign(:membership_review_error, nil)
    |> assign(:releasing_membership, nil)
    |> assign(:membership_release_error, nil)
    |> assign(:membership_release_matches, nil)
    |> assign(:membership_approvable, %{})
    |> assign(:membership_selected, MapSet.new())
    |> assign(:membership_bulk, nil)
    |> assign(:membership_bulk_generation, 0)
    |> stream_configure(:memberships, dom_id: &"ansible-membership-#{&1.id}")
    |> stream(:memberships, [], reset: true)
  end

  @doc "Loads the tab for the given controllers, keeping the current selection when valid."
  def activate(socket, controllers) do
    controller_id = keep_or_first(socket.assigns.membership_controller_id, controllers)

    socket
    |> assign(:membership_controller_id, controller_id)
    |> close_dialogs()
    |> clear_selection()
    |> load_inventories()
    |> load_memberships()
  end

  @doc "Applies a controller/inventory selection from the scope form."
  def select_scope(socket, params, controllers) do
    if bulk_pending?(socket) do
      socket
    else
      apply_scope(socket, params, controllers)
    end
  end

  defp apply_scope(socket, params, controllers) do
    requested_controller = Map.get(params, "controller_id")

    if requested_controller == socket.assigns.membership_controller_id do
      socket
      |> assign(:membership_inventory_id, known_inventory(socket, params["inventory_id"]))
      |> close_dialogs()
      |> clear_selection()
      |> load_memberships()
    else
      socket
      |> assign(:membership_controller_id, keep_or_first(requested_controller, controllers))
      |> assign(:membership_inventory_id, nil)
      |> close_dialogs()
      |> clear_selection()
      |> load_inventories()
      |> load_memberships()
    end
  end

  @doc "Switches the row filter and re-streams the current inventory."
  def filter(socket, filter) when filter in @filters do
    if bulk_pending?(socket) do
      socket
    else
      socket
      |> assign(:membership_filter, filter)
      |> clear_selection()
      |> load_memberships()
    end
  end

  def filter(socket, _filter), do: socket

  @doc """
  Opens the review dialog for one membership from freshly loaded evidence.

  The dialog shows the current proposal, not the possibly older table row, and
  approval submits exactly what the dialog shows.
  """
  def review(socket, id) do
    if bulk_pending?(socket) do
      socket
    else
      socket = close_dialogs(socket)

      case fetch_memberships(socket) do
        {:ok, memberships} -> socket |> put_memberships(memberships) |> open_review(find(memberships, id))
        {:error, socket} -> socket
      end
    end
  end

  def cancel_review(socket) do
    socket
    |> assign(:reviewing_membership, nil)
    |> assign(:membership_review_error, nil)
  end

  @doc "Approves the membership in the open review dialog as the logged-in user."
  def approve(%{assigns: %{reviewing_membership: nil}} = socket) do
    put_flash(socket, :error, "Open a membership review before approving it.")
  end

  def approve(%{assigns: %{reviewing_membership: membership}} = socket) do
    scope = socket.assigns.current_scope

    case automation().approve_membership(scope, membership.id, approval_request(membership)) do
      {:ok, approved} ->
        socket
        |> cancel_review()
        |> put_flash(
          :info,
          "Approved #{display(approved[:host_name])} -> #{display(approved[:canonical_device_uid])}."
        )
        |> load_inventories()
        |> load_memberships()

      {:error, reason} when reason in @stale_reasons ->
        socket
        |> cancel_review()
        |> load_inventories()
        |> reopen_after_change(membership.id)

      {:error, :current_permission_denied} ->
        socket
        |> cancel_review()
        |> put_flash(
          :error,
          "Approval was refused: your account no longer holds ansible.controllers.manage."
        )

      {:error, :human_approval_required} ->
        assign(socket, :membership_review_error, "Approval requires a logged-in human user.")

      {:error, reason} ->
        assign(socket, :membership_review_error, "Approval was rejected: #{format_reason(reason)}.")
    end
  end

  ## Quarantine release --------------------------------------------------------

  @doc """
  Opens the release dialog for one quarantined membership from freshly loaded
  evidence, so the dialog shows the current row rather than the table's copy.
  """
  def review_release(socket, id) do
    if bulk_pending?(socket) do
      socket
    else
      socket = close_dialogs(socket)

      case fetch_memberships(socket) do
        {:ok, memberships} -> socket |> put_memberships(memberships) |> open_release(find(memberships, id))
        {:error, socket} -> socket
      end
    end
  end

  def cancel_release(socket) do
    socket
    |> assign(:releasing_membership, nil)
    |> assign(:membership_release_error, nil)
    |> assign(:membership_release_matches, nil)
  end

  @doc "Releases the membership shown in the release dialog as the logged-in user."
  def release(%{assigns: %{releasing_membership: nil}} = socket) do
    put_flash(socket, :error, "Open a quarantined membership before releasing it.")
  end

  def release(%{assigns: %{releasing_membership: membership}} = socket) do
    scope = socket.assigns.current_scope

    case automation().release_membership(scope, membership.id, release_request(membership)) do
      {:ok, released} ->
        socket
        |> cancel_release()
        |> put_flash(:info, released_message(membership, released))
        |> load_inventories()
        |> load_memberships()

      {:error, {:membership_link_ambiguous, device_uids}} ->
        socket
        |> reload_release(membership.id)
        |> assign(:membership_release_matches, device_uids)
        |> assign(
          :membership_release_error,
          "Not released: #{length(device_uids)} devices carry this AWX host now, so it stays " <>
            "quarantined. Resolve the duplicate devices, then release it again."
        )

      {:error, reason} when reason in @release_stale_reasons ->
        socket
        |> reload_release(membership.id)
        |> assign(
          :membership_release_error,
          "The quarantined membership changed after you opened it, so it was not released. " <>
            "This is its current evidence; confirm again only if you still mean to release it."
        )

      {:error, reason} when reason in @release_gone_reasons ->
        socket
        |> cancel_release()
        |> put_flash(:error, "Not released: #{gone_message(reason)}")
        |> load_inventories()
        |> load_memberships()

      {:error, :current_permission_denied} ->
        socket
        |> cancel_release()
        |> put_flash(:error, "Release was refused: your account no longer holds ansible.controllers.manage.")

      {:error, :human_approval_required} ->
        assign(socket, :membership_release_error, "Releasing a quarantine requires a logged-in human user.")

      {:error, reason} ->
        assign(socket, :membership_release_error, "Release was rejected: #{format_reason(reason)}.")
    end
  end

  @doc "The exact request body the API release route accepts, built from the shown row."
  def release_request(membership) do
    %{
      "controller_id" => to_string(membership.controller_id),
      "inventory_id" => membership.inventory_id,
      "awx_host_id" => membership.awx_host_id,
      "source_generation" => membership.source_generation,
      "source_fingerprint" => membership.source_fingerprint,
      "link_evidence_digest" => membership.link_evidence_digest
    }
  end

  @doc "True when the membership is quarantined, current and carries an evidence digest to bind to."
  def releasable?(membership) do
    membership.link_disposition == :quarantined and Map.get(membership, :current, true) == true and
      is_binary(membership.link_evidence_digest)
  end

  @doc "Operator-facing explanation of why a membership was quarantined."
  def quarantine_reason_label(membership) do
    Map.get(
      @quarantine_reason_labels,
      Map.get(membership, :quarantine_reason),
      "Cause not reported for this row."
    )
  end

  @doc "The devices the membership's current link evidence lists."
  def matching_devices(membership), do: evidence(membership, "matching_device_uids") || []

  defp open_release(socket, nil) do
    put_flash(socket, :error, "That membership is no longer current in this inventory.")
  end

  defp open_release(socket, membership) do
    if releasable?(membership) do
      assign(socket, :releasing_membership, membership)
    else
      put_flash(socket, :error, "Only a current, quarantined membership can be released.")
    end
  end

  # Keeps the dialog on the freshly loaded row when it can still be released;
  # otherwise closes it and says why. Never submits anything.
  defp reload_release(socket, id) do
    socket = cancel_release(socket)

    case fetch_memberships(socket) do
      {:ok, memberships} ->
        socket = put_memberships(socket, memberships)
        membership = find(memberships, id)

        if membership && releasable?(membership) do
          assign(socket, :releasing_membership, membership)
        else
          put_flash(socket, :error, "The membership changed and is no longer quarantined here.")
        end

      {:error, socket} ->
        socket
    end
  end

  defp released_message(membership, %{link_disposition: :proposed} = released) do
    "Released #{display(membership.host_name)}: it is now proposed for " <>
      "#{display(released[:canonical_device_uid])}. Review and approve it before it can launch."
  end

  defp released_message(membership, _released) do
    "Released #{display(membership.host_name)}: no device carries this AWX host now, so it is " <>
      "unlinked. Inventory sync proposes a device when one matches."
  end

  defp gone_message(:membership_not_quarantined), do: "the membership is no longer quarantined."
  defp gone_message(:membership_not_current), do: "the host is no longer current in this inventory."
  defp gone_message(:membership_not_found), do: "the membership no longer exists."

  ## Bulk approval -------------------------------------------------------------

  @doc "Selects or clears one approvable row of the current view."
  def toggle_selection(socket, id) do
    case {bulk_pending?(socket), Map.fetch(socket.assigns.membership_approvable, id)} do
      {false, {:ok, membership}} ->
        selected = socket.assigns.membership_selected

        selected =
          if MapSet.member?(selected, id), do: MapSet.delete(selected, id), else: MapSet.put(selected, id)

        socket
        |> assign(:membership_selected, selected)
        |> stream_insert(:memberships, membership)

      _other ->
        socket
    end
  end

  @doc "Selects every approvable row of the current view, or clears them when all are selected."
  def toggle_all(socket) do
    if bulk_pending?(socket) do
      socket
    else
      approvable = socket.assigns.membership_approvable
      ids = approvable |> Map.keys() |> MapSet.new()

      selected =
        if MapSet.size(ids) > 0 and MapSet.subset?(ids, socket.assigns.membership_selected),
          do: MapSet.new(),
          else: ids

      socket
      |> assign(:membership_selected, selected)
      |> restream_approvable()
    end
  end

  @doc """
  Opens the bulk dialog for the selected rows from freshly loaded evidence.

  Rows that are no longer current or approvable are listed with their reason
  and dropped from the selection; nothing is submitted until the operator
  confirms.
  """
  def review_selected(socket) do
    cond do
      bulk_pending?(socket) ->
        socket

      MapSet.size(socket.assigns.membership_selected) == 0 ->
        put_flash(socket, :error, "Select at least one membership to approve.")

      true ->
        selected = socket.assigns.membership_selected
        socket = cancel_review(socket)

        case fetch_memberships(socket) do
          {:ok, memberships} ->
            {items, excluded} = partition_selected(memberships, selected)

            socket
            |> put_memberships(memberships)
            |> next_bulk_generation()
            |> assign(:membership_bulk, bulk(items, excluded, []))

          {:error, socket} ->
            socket
        end
    end
  end

  def cancel_bulk(socket) do
    if bulk_pending?(socket) do
      socket
    else
      socket
      |> next_bulk_generation()
      |> assign(:membership_bulk, nil)
    end
  end

  @doc "Approves every row shown in the bulk dialog, each with its own shown tuple."
  def approve_selected(%{assigns: %{membership_bulk: %{pending?: false, items: [_ | _] = items}}} = socket) do
    scope = socket.assigns.current_scope
    generation = socket.assigns.membership_bulk_generation

    socket
    |> assign(:membership_bulk, %{socket.assigns.membership_bulk | pending?: true})
    |> start_async(:ansible_membership_bulk_approve, fn ->
      {generation,
       Enum.map(items, fn membership ->
         {membership, automation().approve_membership(scope, membership.id, approval_request(membership))}
       end)}
    end)
  end

  def approve_selected(%{assigns: %{membership_bulk: %{pending?: true}}} = socket), do: socket

  def approve_selected(socket) do
    put_flash(socket, :error, "Open the selected memberships for review before approving them.")
  end

  @doc """
  Applies the per-row results of `approve_selected/1`.

  Approved rows leave the selection. A row refused because its proposal changed
  stays selected and is shown again with its fresh evidence when it is still
  approvable; every other refusal is reported with its reason.
  """
  def bulk_approved(socket, {:ok, {generation, results}}) do
    current? = generation == socket.assigns.membership_bulk_generation
    socket = socket |> load_inventories() |> flash_summary(results)

    case fetch_memberships(socket) do
      {:ok, memberships} when current? ->
        retry_ids =
          for {membership, {:error, reason}} <- results,
              reason in @stale_reasons,
              into: MapSet.new(),
              do: to_string(membership.id)

        items =
          memberships
          |> Enum.filter(&(MapSet.member?(retry_ids, to_string(&1.id)) and approvable?(&1)))
          |> Enum.sort_by(& &1.awx_host_id)

        socket
        |> assign(:membership_selected, MapSet.new(items, &to_string(&1.id)))
        |> put_memberships(memberships)
        |> assign(:membership_bulk, bulk(items, [], Enum.map(results, &outcome/1)))

      {:ok, memberships} ->
        put_memberships(socket, memberships)

      {:error, socket} ->
        if current?, do: assign(socket, :membership_bulk, nil), else: socket
    end
  end

  def bulk_approved(socket, _crashed) do
    socket
    |> assign(:membership_bulk, nil)
    |> put_flash(:error, "Bulk approval stopped unexpectedly. The list below shows what was approved.")
    |> load_inventories()
    |> load_memberships()
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

  defp open_review(socket, nil) do
    put_flash(socket, :error, "That membership is no longer current in this inventory.")
  end

  defp open_review(socket, membership) do
    if approvable?(membership) do
      socket
      |> assign(:reviewing_membership, membership)
      |> assign(:membership_review_error, nil)
    else
      put_flash(socket, :error, "This membership cannot be approved. #{blocked_reason(membership)}")
    end
  end

  defp reopen_after_change(socket, id) do
    case fetch_memberships(socket) do
      {:ok, memberships} ->
        socket = put_memberships(socket, memberships)

        case find(memberships, id) do
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
              |> assign(
                :membership_review_error,
                "The proposal changed after you reviewed it, so it was not approved. " <>
                  "This is the current evidence; review it before approving again."
              )
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

  @doc "Closes every Memberships dialog and ignores any in-flight bulk result."
  def close_dialogs(socket) do
    socket
    |> cancel_review()
    |> cancel_release()
    |> next_bulk_generation()
    |> assign(:membership_bulk, nil)
  end

  defp clear_selection(socket), do: assign(socket, :membership_selected, MapSet.new())

  defp bulk_pending?(socket), do: match?(%{pending?: true}, socket.assigns.membership_bulk)

  defp next_bulk_generation(socket) do
    assign(socket, :membership_bulk_generation, socket.assigns.membership_bulk_generation + 1)
  end

  defp bulk(items, excluded, outcomes) do
    %{items: items, excluded: excluded, outcomes: outcomes, pending?: false}
  end

  defp partition_selected(memberships, selected) do
    by_id = Map.new(memberships, &{to_string(&1.id), &1})

    {items, excluded} =
      selected
      |> Enum.sort()
      |> Enum.map(&{&1, Map.get(by_id, &1)})
      |> Enum.split_with(fn {_id, membership} -> membership != nil and approvable?(membership) end)

    {items |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.awx_host_id), Enum.map(excluded, &exclusion/1)}
  end

  defp exclusion({id, nil}), do: %{id: id, host_name: nil, message: "No longer current in this inventory."}
  defp exclusion({id, membership}), do: %{id: id, host_name: membership.host_name, message: blocked_reason(membership)}

  defp outcome({membership, {:ok, approved}}) do
    %{
      id: to_string(membership.id),
      host_name: membership.host_name,
      approved?: true,
      message: "Approved -> #{display(approved[:canonical_device_uid])}."
    }
  end

  defp outcome({membership, {:error, reason}}) do
    %{
      id: to_string(membership.id),
      host_name: membership.host_name,
      approved?: false,
      message: refusal_message(reason)
    }
  end

  defp refusal_message(reason) when reason in [:membership_identity_changed, :membership_evidence_changed],
    do: "Not approved: the evidence changed after it was shown."

  defp refusal_message(:membership_not_current), do: "Not approved: no longer current in this inventory."
  defp refusal_message(:membership_not_proposed), do: "Not approved: no longer a pending proposal."
  defp refusal_message(:membership_link_ambiguous), do: "Not approved: the link is now ambiguous."
  defp refusal_message(:membership_not_found), do: "Not approved: the membership was not found."

  defp refusal_message(:current_permission_denied),
    do: "Refused: your account no longer holds ansible.controllers.manage."

  defp refusal_message(:human_approval_required), do: "Refused: approval requires a logged-in human user."
  defp refusal_message(reason), do: "Rejected: #{format_reason(reason)}."

  defp flash_summary(socket, results) do
    approved = Enum.count(results, &match?({_membership, {:ok, _approved}}, &1))
    total = length(results)

    if approved == total do
      put_flash(socket, :info, "Approved #{approved} of #{total} memberships.")
    else
      put_flash(
        socket,
        :error,
        "Approved #{approved} of #{total} memberships; #{total - approved} were not approved."
      )
    end
  end

  defp restream_approvable(socket) do
    Enum.reduce(Map.values(socket.assigns.membership_approvable), socket, fn membership, socket ->
      stream_insert(socket, :memberships, membership)
    end)
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

  # Every reload re-derives the filter counts, the selected inventory's picker
  # count, and the approvable rows from the same list, so they cannot disagree.
  # Selected rows that are no longer approvable in this view leave the selection.
  defp put_memberships(socket, memberships) do
    visible = Enum.filter(memberships, &visible?(&1, socket.assigns.membership_filter))
    counts = counts(memberships)

    approvable =
      for membership <- visible, approvable?(membership), into: %{}, do: {to_string(membership.id), membership}

    selected = MapSet.filter(socket.assigns.membership_selected, &Map.has_key?(approvable, &1))

    socket
    |> assign(:membership_counts, counts)
    |> assign(:membership_approvable, approvable)
    |> assign(:membership_selected, selected)
    |> assign(
      :membership_inventories,
      put_inventory_count(socket.assigns.membership_inventories, socket.assigns.membership_inventory_id, counts)
    )
    |> stream(:memberships, visible, reset: true)
  end

  defp put_inventory_count(inventories, inventory_id, counts) do
    Enum.map(inventories, fn
      %{inventory_id: ^inventory_id} = inventory -> %{inventory | needs_review: counts.needs_review}
      inventory -> inventory
    end)
  end

  defp counts(memberships) do
    %{
      all: length(memberships),
      needs_review: Enum.count(memberships, &needs_review?/1),
      approved: Enum.count(memberships, &(&1.link_disposition == :approved)),
      quarantined: Enum.count(memberships, &(&1.link_disposition == :quarantined)),
      unlinked: Enum.count(memberships, &(&1.link_disposition == :unlinked))
    }
  end

  defp visible?(_membership, "all"), do: true
  defp visible?(membership, "needs_review"), do: needs_review?(membership)
  defp visible?(membership, "approved"), do: membership.link_disposition == :approved
  defp visible?(membership, "quarantined"), do: membership.link_disposition == :quarantined
  defp visible?(membership, "unlinked"), do: membership.link_disposition == :unlinked

  defp find(memberships, id), do: Enum.find(memberships, &(to_string(&1.id) == to_string(id)))

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
    now =
      case match_count(membership) do
        count when is_integer(count) and count > 1 ->
          " #{count} devices match this AWX host now; resolve the duplicates before releasing it."

        _ ->
          ""
      end

    "Quarantined: it cannot be approved or force-linked." <>
      now <> " Release it to re-check current devices; a released membership still needs approval."
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
