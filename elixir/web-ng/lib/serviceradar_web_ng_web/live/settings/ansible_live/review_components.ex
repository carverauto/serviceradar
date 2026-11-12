defmodule ServiceRadarWebNGWeb.Settings.AnsibleLive.ReviewComponents do
  @moduledoc """
  Memberships and template-bindings tabs of the Ansible settings page.

  Display only: state and events live in
  `ServiceRadarWebNGWeb.Settings.AnsibleLive.MembershipReview` and
  `ServiceRadarWebNGWeb.Settings.AnsibleLive.BindingReview`. Nothing here
  renders credential material; the binding review shows AWX credential IDs and
  kinds only.
  """

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.Settings.AnsibleLive.BindingReview
  alias ServiceRadarWebNGWeb.Settings.AnsibleLive.MembershipReview

  ## Memberships -------------------------------------------------------------

  attr :controllers, :list, required: true
  attr :controller_id, :string, default: nil
  attr :inventories, :list, required: true
  attr :inventory_id, :integer, default: nil
  attr :filter, :string, required: true
  attr :counts, :map, required: true
  attr :memberships, :any, required: true
  attr :notice, :string, default: nil
  attr :reviewing, :map, default: nil
  attr :review_error, :string, default: nil
  attr :approvable_count, :integer, required: true
  attr :selected, :any, required: true
  attr :bulk, :map, default: nil
  attr :releasing, :map, default: nil
  attr :release_error, :string, default: nil
  attr :release_matches, :list, default: nil
  attr :timezone, :string, required: true

  def memberships_panel(assigns) do
    assigns =
      assigns
      |> assign(:selected_count, MapSet.size(assigns.selected))
      |> assign(
        :all_selected?,
        assigns.approvable_count > 0 and assigns.approvable_count == MapSet.size(assigns.selected)
      )

    ~H"""
    <p class="text-sm text-sr-muted">
      AWX inventory hosts that inventory sync linked to ServiceRadar devices. A proposed link
      becomes usable for launches only after a human approves its exact evidence here.
    </p>

    <.form
      for={%{}}
      as={:membership_scope}
      id="ansible-membership-scope-form"
      phx-change="select_membership_scope"
      class="flex flex-wrap items-end gap-3"
    >
      <label class="flex flex-col gap-1.5">
        <span class="text-sm font-medium text-sr-ink">Controller</span>
        <select
          id="ansible-membership-controller"
          name="controller_id"
          class={ui_field_class(size: "sm")}
        >
          <option
            :for={ctrl <- @controllers}
            value={ctrl.id}
            selected={to_string(ctrl.id) == @controller_id}
          >
            {ctrl.name}
          </option>
        </select>
      </label>
      <label class="flex flex-col gap-1.5">
        <span class="text-sm font-medium text-sr-ink">AWX inventory</span>
        <select
          id="ansible-membership-inventory"
          name="inventory_id"
          class={ui_field_class(size: "sm")}
          disabled={@inventories == []}
        >
          <option
            :for={inventory <- @inventories}
            value={inventory.inventory_id}
            selected={inventory.inventory_id == @inventory_id}
          >
            Inventory {inventory.inventory_id}{inventory_suffix(inventory)}
          </option>
        </select>
      </label>
    </.form>

    <.ui_alert :if={@notice} variant="warning" id="ansible-membership-notice">{@notice}</.ui_alert>

    <p :if={@controllers == []} class="text-sm text-sr-muted">
      Register an AWX controller on the Controllers tab first.
    </p>

    <p
      :if={@controllers != [] and @inventories == [] and is_nil(@notice)}
      class="rounded-lg border border-dashed border-sr-line p-6 text-center text-sm text-sr-muted"
    >
      No current AWX memberships for this controller yet. They appear after inventory sync runs.
    </p>

    <div :if={@inventory_id} class="flex flex-wrap items-center justify-between gap-2">
      <div class="flex flex-wrap gap-2" role="group" aria-label="Membership filter">
        <.ui_button
          :for={{key, label, count_key} <- membership_filters()}
          id={"ansible-membership-filter-#{key}"}
          type="button"
          size="xs"
          variant={if(@filter == key, do: "primary", else: "neutral")}
          phx-click="filter_memberships"
          phx-value-filter={key}
        >
          {label} ({Map.fetch!(@counts, count_key)})
        </.ui_button>
      </div>
      <.ui_button
        :if={@selected_count > 0}
        id="ansible-membership-bulk-open"
        type="button"
        size="xs"
        variant="primary"
        phx-click="review_selected_memberships"
      >
        Approve selected ({@selected_count})
      </.ui_button>
    </div>

    <div :if={@inventory_id} class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface">
      <table class={ui_table_class(zebra: true, size: "sm")}>
        <thead>
          <tr>
            <th class="w-8">
              <input
                :if={@approvable_count > 0}
                id="ansible-membership-select-all"
                type="checkbox"
                class="size-4 cursor-pointer"
                checked={@all_selected?}
                phx-click="toggle_all_memberships"
                aria-label="Select every approvable membership in this view"
                title="Select every approvable membership in this view"
              />
            </th>
            <th>Host</th>
            <th>AWX host</th>
            <th>Link</th>
            <th>Proposed device</th>
            <th>Evidence</th>
            <th>Last seen</th>
            <th class="w-40">Review</th>
          </tr>
        </thead>
        <tbody id="ansible-memberships" phx-update="stream">
          <tr id="ansible-memberships-empty" class="hidden only:table-row">
            <td colspan="8" class="text-center text-sm text-sr-muted">
              No memberships match this filter.
            </td>
          </tr>
          <tr :for={{id, membership} <- @memberships} id={id}>
            <td>
              <input
                :if={MembershipReview.approvable?(membership)}
                id={"ansible-membership-select-#{membership.id}"}
                type="checkbox"
                class="size-4 cursor-pointer"
                checked={MapSet.member?(@selected, to_string(membership.id))}
                phx-click="toggle_membership_selection"
                phx-value-id={membership.id}
                aria-label={"Select #{membership.host_name} for approval"}
              />
            </td>
            <td>
              <div class="font-medium">{membership.host_name}</div>
              <div :if={membership.ansible_host} class="text-xs text-sr-muted">
                <code>{membership.ansible_host}</code>
              </div>
            </td>
            <td><code class="text-xs">{membership.awx_host_id}</code></td>
            <td>
              <div class="flex flex-wrap items-center gap-1">
                <.ui_badge
                  size="sm"
                  variant={MembershipReview.disposition_variant(membership.link_disposition)}
                >
                  {membership.link_disposition}
                </.ui_badge>
                <.ui_badge :if={membership.enabled != true} size="sm" variant="ghost">
                  disabled
                </.ui_badge>
              </div>
              <.quarantine_note
                :if={membership.link_disposition == :quarantined}
                membership={membership}
                timezone={@timezone}
              />
            </td>
            <td>
              <.link
                :if={membership.canonical_device_uid}
                navigate={~p"/devices/#{membership.canonical_device_uid}"}
                class="text-xs font-mono underline"
              >
                {membership.canonical_device_uid}
              </.link>
              <span :if={is_nil(membership.canonical_device_uid)} class="text-xs text-sr-muted">
                none
              </span>
            </td>
            <td class="text-xs">
              <div>{MembershipReview.evidence_kind(membership) || "-"}</div>
              <div class="text-sr-muted">
                matches: {MembershipReview.match_count(membership) || 0}
              </div>
            </td>
            <td class="text-xs">
              <.user_time
                :if={membership.last_seen_at}
                id={"ansible-membership-#{membership.id}-last-seen"}
                value={membership.last_seen_at}
                timezone={@timezone}
                style={:compact}
              />
            </td>
            <td>
              <.ui_button
                :if={MembershipReview.approvable?(membership)}
                id={"ansible-membership-review-#{membership.id}"}
                type="button"
                size="xs"
                variant="primary"
                phx-click="review_membership"
                phx-value-id={membership.id}
              >
                Review
              </.ui_button>
              <.ui_button
                :if={MembershipReview.releasable?(membership)}
                id={"ansible-membership-release-#{membership.id}"}
                type="button"
                size="xs"
                variant="neutral"
                phx-click="review_membership_release"
                phx-value-id={membership.id}
              >
                Release quarantine
              </.ui_button>
              <p
                :if={!MembershipReview.approvable?(membership)}
                id={"ansible-membership-reason-#{membership.id}"}
                class="text-xs text-sr-muted"
              >
                {MembershipReview.blocked_reason(membership)}
              </p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <.membership_review_modal :if={@reviewing} membership={@reviewing} error={@review_error} />
    <.membership_bulk_modal :if={@bulk} bulk={@bulk} />
    <.membership_release_modal
      :if={@releasing}
      membership={@releasing}
      error={@release_error}
      matches={@release_matches}
      timezone={@timezone}
    />
    """
  end

  attr :membership, :map, required: true
  attr :timezone, :string, required: true

  defp quarantine_note(assigns) do
    ~H"""
    <div id={"ansible-membership-quarantine-#{@membership.id}"} class="mt-1 max-w-xs text-xs">
      <div>{MembershipReview.quarantine_reason_label(@membership)}</div>
      <div class="text-sr-muted">
        <span :if={is_nil(@membership[:quarantined_at])}>Quarantined at: unknown</span>
        <span :if={@membership[:quarantined_at]}>
          Quarantined
          <.user_time
            id={"ansible-membership-#{@membership.id}-quarantined-at"}
            value={@membership.quarantined_at}
            timezone={@timezone}
            style={:compact}
          />
        </span>
      </div>
    </div>
    """
  end

  attr :membership, :map, required: true
  attr :error, :string, default: nil
  attr :matches, :list, default: nil
  attr :timezone, :string, required: true

  defp membership_release_modal(assigns) do
    assigns = assign(assigns, :current_matches, MembershipReview.matching_devices(assigns.membership))

    ~H"""
    <.ui_modal
      id="ansible-membership-release"
      size="lg"
      on_cancel="cancel_membership_release"
      data-return-focus={"#ansible-membership-release-#{@membership.id}"}
    >
      <:title>Release membership quarantine</:title>

      <.ui_alert :if={@error} variant="error" id="ansible-membership-release-error">
        {@error}
      </.ui_alert>

      <div :if={@matches} id="ansible-membership-release-ambiguous" class="space-y-1">
        <p class="text-sm font-medium">Devices carrying this AWX host now</p>
        <ul class="space-y-1 text-sm">
          <li :for={uid <- @matches}>
            <.link navigate={~p"/devices/#{uid}"} class="font-mono text-xs underline">{uid}</.link>
          </li>
        </ul>
      </div>

      <p class="text-sm text-sr-muted">
        Releasing re-checks which ServiceRadar devices carry AWX host
        <strong>{@membership.host_name}</strong>
        now, recorded as you. If exactly one does, the membership becomes proposed and still
        needs a normal Review and approval before it can launch. If none does, it becomes
        unlinked. If several do, nothing changes. A release never approves a link, and it does
        not clear a device target hold.
      </p>

      <dl class="grid grid-cols-1 gap-x-6 gap-y-2 text-sm md:grid-cols-2">
        <div class="flex min-w-0 flex-col md:col-span-2">
          <dt class="text-xs text-sr-muted">Why it was quarantined</dt>
          <dd id="ansible-membership-release-reason">
            {MembershipReview.quarantine_reason_label(@membership)}
          </dd>
        </div>
        <div class="flex min-w-0 flex-col">
          <dt class="text-xs text-sr-muted">Quarantined at</dt>
          <dd id="ansible-membership-release-quarantined-at">
            <span :if={is_nil(@membership[:quarantined_at])}>unknown</span>
            <.user_time
              :if={@membership[:quarantined_at]}
              id="ansible-membership-release-quarantined-at-time"
              value={@membership.quarantined_at}
              timezone={@timezone}
              style={:compact}
            />
          </dd>
        </div>
        <.review_row label="Controller" value={@membership.controller_id} mono />
        <.review_row label="AWX inventory" value={@membership.inventory_id} mono />
        <.review_row label="AWX host ID" value={@membership.awx_host_id} mono />
        <.review_row label="Host address" value={@membership.ansible_host} mono />
        <.review_row
          label="Last synced evidence"
          value={"#{MembershipReview.evidence_kind(@membership)}, #{MembershipReview.match_count(@membership) || 0} match"}
        />
        <div class="flex min-w-0 flex-col md:col-span-2">
          <dt class="text-xs text-sr-muted">Devices in the last synced evidence</dt>
          <dd id="ansible-membership-release-evidence-devices" class="break-all font-mono text-xs">
            {if(@current_matches == [], do: "none", else: Enum.join(@current_matches, ", "))}
          </dd>
        </div>
        <.review_row label="Source generation" value={@membership.source_generation} mono />
        <.review_row label="Source fingerprint" value={@membership.source_fingerprint} mono />
        <.review_row label="Evidence digest" value={@membership.link_evidence_digest} mono />
      </dl>

      <div class="sr-ui-modal-action">
        <.ui_button
          type="button"
          size="sm"
          variant="ghost"
          phx-click="cancel_membership_release"
          data-dialog-autofocus
        >
          Cancel
        </.ui_button>
        <.ui_button
          id="ansible-membership-release-confirm"
          type="button"
          size="sm"
          variant="primary"
          phx-click="release_membership"
        >
          Release quarantine
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  attr :membership, :map, required: true
  attr :error, :string, default: nil

  defp membership_review_modal(assigns) do
    ~H"""
    <.ui_modal
      id="ansible-membership-review"
      size="lg"
      on_cancel="cancel_membership_review"
      data-return-focus={"#ansible-membership-review-#{@membership.id}"}
    >
      <:title>Approve membership link</:title>

      <.ui_alert :if={@error} variant="error" id="ansible-membership-review-error">
        {@error}
      </.ui_alert>

      <p class="text-sm text-sr-muted">
        Approval links AWX host <strong>{@membership.host_name}</strong> to the device below for
        launches, recorded as you. ServiceRadar submits exactly this evidence; if the proposal
        changed since it was loaded, the approval is refused and the new evidence is shown.
      </p>

      <dl class="grid grid-cols-1 gap-x-6 gap-y-2 text-sm md:grid-cols-2">
        <.review_row label="Controller" value={@membership.controller_id} mono />
        <.review_row label="AWX inventory" value={@membership.inventory_id} mono />
        <.review_row label="AWX host ID" value={@membership.awx_host_id} mono />
        <.review_row label="Host address" value={@membership.ansible_host} mono />
        <div class="flex flex-col">
          <dt class="text-xs text-sr-muted">Device</dt>
          <dd>
            <.link
              navigate={~p"/devices/#{@membership.canonical_device_uid}"}
              class="font-mono text-xs underline"
            >
              {@membership.canonical_device_uid}
            </.link>
          </dd>
        </div>
        <.review_row
          label="Evidence"
          value={"#{MembershipReview.evidence_kind(@membership)}, #{MembershipReview.match_count(@membership)} match"}
        />
        <.review_row label="Source generation" value={@membership.source_generation} mono />
        <.review_row label="Source fingerprint" value={@membership.source_fingerprint} mono />
        <.review_row label="Evidence digest" value={@membership.link_evidence_digest} mono />
      </dl>

      <div class="sr-ui-modal-action">
        <.ui_button
          type="button"
          size="sm"
          variant="ghost"
          phx-click="cancel_membership_review"
          data-dialog-autofocus
        >
          Cancel
        </.ui_button>
        <.ui_button
          id="ansible-membership-approve"
          type="button"
          size="sm"
          variant="primary"
          phx-click="approve_membership"
        >
          Approve link
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  attr :bulk, :map, required: true

  defp membership_bulk_modal(assigns) do
    ~H"""
    <.ui_modal
      id="ansible-membership-bulk-review"
      size="6xl"
      on_cancel="cancel_bulk_membership_review"
      data-return-focus="#ansible-membership-filter-needs_review"
    >
      <:title>Approve selected membership links</:title>

      <div :if={@bulk.outcomes != []} id="ansible-membership-bulk-outcomes" class="space-y-1">
        <p class="text-sm font-medium">Results</p>
        <ul class="space-y-1 text-sm">
          <li
            :for={outcome <- @bulk.outcomes}
            id={"ansible-membership-bulk-outcome-#{outcome.id}"}
            class="flex flex-wrap items-center gap-2"
          >
            <.ui_badge size="sm" variant={if(outcome.approved?, do: "success", else: "error")}>
              {if(outcome.approved?, do: "approved", else: "not approved")}
            </.ui_badge>
            <span class="font-medium">{outcome.host_name}</span>
            <span class="text-sr-muted">{outcome.message}</span>
          </li>
        </ul>
      </div>

      <div :if={@bulk.excluded != []} id="ansible-membership-bulk-excluded" class="space-y-1">
        <p class="text-sm font-medium">Not included</p>
        <ul class="space-y-1 text-sm">
          <li
            :for={excluded <- @bulk.excluded}
            id={"ansible-membership-bulk-excluded-#{excluded.id}"}
            class="text-sr-muted"
          >
            <span class="font-medium text-sr-ink">{excluded.host_name || excluded.id}</span>: {excluded.message}
          </li>
        </ul>
      </div>

      <.ui_alert
        :if={@bulk.outcomes != [] and @bulk.items != []}
        variant="warning"
        id="ansible-membership-bulk-changed"
      >
        These memberships changed after you reviewed them, so they were not approved. This is
        their current evidence; confirm again only if it is what you mean to approve.
      </.ui_alert>

      <p :if={@bulk.items != [] and @bulk.outcomes == []} class="text-sm text-sr-muted">
        Approval links each AWX host below to the device shown, recorded as you. ServiceRadar
        submits exactly the evidence shown for each one, one approval per membership; any proposal
        that changed since it was loaded is refused and shown again.
      </p>

      <div :if={@bulk.items != []} class="overflow-x-auto rounded-lg border border-sr-line">
        <table class={ui_table_class(size: "sm")}>
          <thead>
            <tr>
              <th>Host</th>
              <th>AWX host</th>
              <th>Proposed device</th>
              <th>Evidence</th>
              <th>Source generation / fingerprint</th>
              <th>Evidence digest</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={membership <- @bulk.items}
              id={"ansible-membership-bulk-item-#{membership.id}"}
            >
              <td>
                <div class="font-medium">{membership.host_name}</div>
                <code :if={membership.ansible_host} class="text-xs text-sr-muted">
                  {membership.ansible_host}
                </code>
              </td>
              <td><code class="text-xs">{membership.awx_host_id}</code></td>
              <td><code class="break-all text-xs">{membership.canonical_device_uid}</code></td>
              <td class="text-xs">
                {MembershipReview.evidence_kind(membership)}, {MembershipReview.match_count(
                  membership
                )} match
              </td>
              <td class="text-xs">
                <code>{membership.source_generation}</code>
                <code class="block break-all text-sr-muted">{membership.source_fingerprint}</code>
              </td>
              <td><code class="break-all text-xs">{membership.link_evidence_digest}</code></td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@bulk.pending?} id="ansible-membership-bulk-pending" class="text-sm text-sr-muted">
        Approving each membership with its shown evidence…
      </p>

      <div class="sr-ui-modal-action">
        <.ui_button
          type="button"
          size="sm"
          variant="ghost"
          disabled={@bulk.pending?}
          phx-click="cancel_bulk_membership_review"
          data-dialog-autofocus
        >
          {if(@bulk.items == [], do: "Close", else: "Cancel")}
        </.ui_button>
        <.ui_button
          :if={@bulk.items != []}
          id="ansible-membership-bulk-approve"
          type="button"
          size="sm"
          variant="primary"
          disabled={@bulk.pending?}
          phx-click="approve_selected_memberships"
        >
          Approve {length(@bulk.items)} {if(length(@bulk.items) == 1, do: "link", else: "links")}
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  ## Template bindings -------------------------------------------------------

  attr :controllers, :list, required: true
  attr :controller_id, :string, default: nil
  attr :templates, :list, required: true
  attr :template_id, :integer, default: nil
  attr :notice, :string, default: nil
  attr :versions, :any, required: true
  attr :version_count, :integer, required: true
  attr :show_form, :boolean, required: true
  attr :form, :any, required: true
  attr :choices, :any, required: true
  attr :choice_count, :integer, required: true
  attr :choice_notice, :string, default: nil
  attr :inventories, :list, required: true
  attr :review, :map, default: nil
  attr :pending, :atom, default: nil
  attr :revoking, :map, default: nil
  attr :revoke_form, :any, required: true
  attr :revoke_error, :string, default: nil
  attr :timezone, :string, required: true

  def bindings_panel(assigns) do
    ~H"""
    <p class="text-sm text-sr-muted">
      A binding pins one existing AWX job template to reviewed project, revision, inventory,
      credentials, and execution environment. These actions review existing AWX configuration;
      they do not create or change anything in AWX.
    </p>

    <datalist id="ansible-binding-template-options">
      <option :for={template <- @templates} value={template.job_template_id}>
        {template.name}
      </option>
    </datalist>
    <datalist id="ansible-binding-inventory-options">
      <option :for={inventory <- @inventories} value={inventory.inventory_id}>
        Inventory {inventory.inventory_id}
      </option>
    </datalist>

    <div class="flex flex-wrap items-end justify-between gap-3">
      <.form
        for={%{}}
        as={:binding_scope}
        id="ansible-binding-scope-form"
        phx-change="select_binding_scope"
        class="flex flex-wrap items-end gap-3"
      >
        <label class="flex flex-col gap-1.5">
          <span class="text-sm font-medium text-sr-ink">Controller</span>
          <select
            id="ansible-binding-controller"
            name="controller_id"
            disabled={not is_nil(@pending)}
            class={ui_field_class(size: "sm")}
          >
            <option
              :for={ctrl <- @controllers}
              value={ctrl.id}
              selected={to_string(ctrl.id) == @controller_id}
            >
              {ctrl.name}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1.5">
          <span class="text-sm font-medium text-sr-ink">AWX job template ID</span>
          <input
            id="ansible-binding-template"
            type="text"
            inputmode="numeric"
            name="template_id"
            list="ansible-binding-template-options"
            value={@template_id}
            phx-debounce="400"
            disabled={not is_nil(@pending)}
            class={ui_field_class(size: "sm", mono: true)}
            placeholder="Template ID"
          />
        </label>
      </.form>

      <.ui_button
        :if={@controller_id && !@show_form}
        id="ansible-binding-new"
        type="button"
        size="sm"
        variant="primary"
        disabled={not is_nil(@pending)}
        phx-click="new_binding_review"
      >
        + Review a binding
      </.ui_button>
    </div>

    <.ui_alert :if={@notice} variant="warning" id="ansible-binding-notice">{@notice}</.ui_alert>

    <.binding_form
      :if={@show_form}
      form={@form}
      choices={@choices}
      choice_count={@choice_count}
      choice_notice={@choice_notice}
      pending={@pending}
    />

    <.binding_review_modal :if={@review} review={@review} pending={@pending} />

    <p
      :if={@controller_id && is_nil(@template_id)}
      id="ansible-binding-choose-template"
      class="text-sm text-sr-muted"
    >
      Enter or pick an AWX job template ID to list its binding versions.
    </p>

    <div :if={@template_id} class="overflow-x-auto rounded-lg border border-sr-line bg-sr-surface">
      <table class={ui_table_class(zebra: true, size: "sm")}>
        <thead>
          <tr>
            <th>Version</th>
            <th>State</th>
            <th>Expires</th>
            <th>Inventory</th>
            <th>Project / revision</th>
            <th>Content</th>
            <th>Modes</th>
            <th class="w-28">Actions</th>
          </tr>
        </thead>
        <tbody id="ansible-binding-versions" phx-update="stream">
          <tr id="ansible-binding-versions-empty" class="hidden only:table-row">
            <td colspan="8" class="text-center text-sm text-sr-muted">
              No binding versions for template {@template_id}.
            </td>
          </tr>
          <tr :for={{id, binding} <- @versions} id={id}>
            <td><code class="text-xs">v{binding.binding_version}</code></td>
            <td><.binding_state binding={binding} /></td>
            <td class="text-xs">
              <.user_time
                :if={binding.approval_expires_at}
                id={"ansible-binding-#{binding.id}-expires"}
                value={binding.approval_expires_at}
                timezone={@timezone}
                style={:compact}
              />
            </td>
            <td class="text-xs">
              {binding.inventory_policy}: {Enum.join(binding.allowed_inventory_ids || [], ", ")}
            </td>
            <td class="text-xs">
              <div>project {binding.project_id}</div>
              <code title={binding.scm_revision}>{BindingReview.short_digest(binding.scm_revision)}</code>
            </td>
            <td class="text-xs">
              <code title={binding.content_sha256}>{BindingReview.short_digest(binding.content_sha256)}</code>
            </td>
            <td class="text-xs">{BindingReview.modes(binding)}</td>
            <td>
              <.ui_button
                :if={BindingReview.revocable?(binding)}
                id={"ansible-binding-revoke-#{binding.id}"}
                type="button"
                size="xs"
                variant="outline"
                phx-click="start_revoke_binding"
                phx-value-id={binding.id}
              >
                Revoke
              </.ui_button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <.revoke_modal :if={@revoking} binding={@revoking} form={@revoke_form} error={@revoke_error} />
    """
  end

  attr :binding, :map, required: true

  defp binding_state(assigns) do
    assigns = assign(assigns, :state, BindingReview.state(assigns.binding))

    ~H"""
    <.ui_badge size="sm" variant={elem(@state, 1)}>{elem(@state, 0)}</.ui_badge>
    """
  end

  attr :form, :any, required: true
  attr :choices, :any, required: true
  attr :choice_count, :integer, required: true
  attr :choice_notice, :string, default: nil
  attr :pending, :atom, default: nil

  defp binding_form(assigns) do
    assigns =
      assign(
        assigns,
        :selected_memberships,
        assigns.form |> Phoenix.HTML.Form.input_value(:membership_ids) |> List.wrap()
      )

    ~H"""
    <div class="rounded-lg border border-sr-line bg-sr-subtle/60 p-4">
      <h2 class="text-lg font-medium">Review a binding version</h2>
      <p class="mb-3 text-sm text-sr-muted">
        Enter the AWX objects to bind. Prepare reads them from AWX and shows what it observed;
        nothing is approved until you inspect that review and create the binding.
      </p>

      <.form
        for={@form}
        id="ansible-binding-form"
        phx-change="validate_binding"
        phx-submit="prepare_binding"
      >
        <fieldset disabled={not is_nil(@pending)} class="grid grid-cols-1 gap-3 md:grid-cols-3">
          <.binding_field
            form={@form}
            field={:template_id}
            label="Job template ID"
            list="ansible-binding-template-options"
          />
          <.binding_field form={@form} field={:project_id} label="Project ID" />
          <.binding_field
            form={@form}
            field={:inventory_id}
            label="Inventory ID"
            list="ansible-binding-inventory-options"
            help="Inventories with current memberships are suggested."
          />
          <.binding_field
            form={@form}
            field={:credential_ids}
            label="Credential IDs"
            help="AWX credential IDs, comma separated. IDs only; no secret values."
          />
          <.binding_field form={@form} field={:machine_credential_id} label="Machine credential ID" />
          <.binding_field
            form={@form}
            field={:execution_environment_id}
            label="Execution environment ID"
          />

          <p class="text-xs text-sr-muted md:col-span-3">
            Picking a job template prefills its project and inventory from the catalog sync when
            known. Prepare re-reads AWX, and its review is what you approve.
          </p>

          <fieldset class="fieldset rounded-sr-surface border border-sr-line p-3 md:col-span-3">
            <legend class="fieldset-legend">Approved memberships ({@choice_count})</legend>
            <input type="hidden" name="binding[membership_ids][]" value="" />
            <p :if={@choice_notice} id="ansible-binding-choice-notice" class="text-xs text-sr-muted">
              {@choice_notice}
            </p>
            <div
              id="ansible-binding-choices"
              phx-update="stream"
              class="max-h-60 space-y-1 overflow-y-auto"
            >
              <label
                :for={{id, membership} <- @choices}
                id={id}
                class="flex items-center gap-2 text-sm"
              >
                <input
                  type="checkbox"
                  name="binding[membership_ids][]"
                  value={membership.id}
                  checked={to_string(membership.id) in @selected_memberships}
                />
                <span class="font-medium">{membership.host_name}</span>
                <code class="text-xs text-sr-muted">host {membership.awx_host_id}</code>
                <code class="text-xs text-sr-muted">{membership.canonical_device_uid}</code>
              </label>
            </div>
          </fieldset>

          <.binding_field
            form={@form}
            field={:content_sha256}
            label="Content SHA-256 (you attest)"
            help="SHA-256 of the playbook content at the pinned revision, computed by you. AWX does not report it."
            mono
          />
          <.binding_field
            form={@form}
            field={:review_ticket}
            label="Review ticket (you attest)"
            help="The change or review record that approved this content."
          />
          <.binding_field
            form={@form}
            field={:approval_ttl_seconds}
            label="Approval TTL (s)"
            help="60 to 86400. Default 3600."
          />

          <label class="flex flex-col gap-1.5 md:col-span-3">
            <span class="text-sm font-medium text-sr-ink">Input schema (optional)</span>
            <span class="text-xs text-sr-muted">
              JSON object declaring typed, non-secret launch inputs. Declarations only; values are
              entered at launch and password, raw variable, and transport fields are rejected.
            </span>
            <textarea
              id="ansible-binding-input-schema"
              name="binding[input_schema]"
              rows="3"
              class={ui_field_class(size: "sm", mono: true)}
            >{Phoenix.HTML.Form.input_value(@form, :input_schema)}</textarea>
          </label>
          <label class="flex flex-col gap-1.5 md:col-span-3">
            <span class="text-sm font-medium text-sr-ink">Input classifications (optional)</span>
            <textarea
              id="ansible-binding-input-classifications"
              name="binding[input_classifications]"
              rows="2"
              class={ui_field_class(size: "sm", mono: true)}
            >{Phoenix.HTML.Form.input_value(@form, :input_classifications)}</textarea>
          </label>
        </fieldset>

        <div class="flex justify-end gap-2 pt-3">
          <.ui_button
            type="button"
            size="sm"
            variant="ghost"
            disabled={@pending == :create}
            phx-click="cancel_binding_form"
          >
            Cancel
          </.ui_button>
          <.ui_button
            id="ansible-binding-prepare"
            type="submit"
            size="sm"
            variant="primary"
            disabled={not is_nil(@pending)}
          >
            Prepare review
          </.ui_button>
        </div>
        <p
          :if={@pending in [:prepare, :reprepare]}
          id="ansible-binding-pending"
          class="pt-2 text-right text-sm text-sr-muted"
        >
          Reading the template, project, inventory, and credentials from AWX through the
          controller's agent…
        </p>
      </.form>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :list, :string, default: nil
  attr :mono, :boolean, default: false

  defp binding_field(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="text-sm font-medium text-sr-ink">{@label}</span>
      <input
        id={"ansible-binding-#{@field}"}
        type="text"
        name={"binding[#{@field}]"}
        value={Phoenix.HTML.Form.input_value(@form, @field)}
        list={@list}
        autocomplete="off"
        class={ui_field_class(size: "sm", mono: @mono)}
      />
      <span :if={@help} class="text-xs text-sr-muted">{@help}</span>
    </label>
    """
  end

  attr :review, :map, required: true
  attr :pending, :atom, default: nil

  defp binding_review_modal(assigns) do
    assigns =
      assigns
      |> assign(:attrs, Map.get(assigns.review.review, "attributes", %{}))
      |> assign(:ttl, Map.get(assigns.review.review, "approval_ttl_seconds"))

    assigns = assign(assigns, :metadata, Map.get(assigns.attrs, "review_metadata") || %{})

    ~H"""
    <.ui_modal
      id="ansible-binding-review"
      size="xl"
      on_cancel="discard_binding_review"
      data-return-focus="#ansible-binding-prepare"
    >
      <:title>Broker-observed review</:title>

      <.ui_alert :if={@review.changed?} variant="warning" id="ansible-binding-review-changed">
        AWX changed after the previous review, so nothing was created. This is the refreshed
        review; inspect it again before creating.
      </.ui_alert>

      <p class="text-sm text-sr-muted">
        Read from AWX through the controller's agent. Create repeats these reads and refuses
        the binding if the result no longer matches this review's digest.
      </p>

      <dl class="grid grid-cols-1 gap-x-6 gap-y-2 text-sm md:grid-cols-3">
        <.review_row label="Job template" value={@attrs["job_template_id"]} mono />
        <.review_row
          label="Inventory policy"
          value={"#{@attrs["inventory_policy"]}: #{fmt(@attrs["allowed_inventory_ids"])}"}
        />
        <.review_row label="Inventory groups" value={fmt(@attrs["inventory_group_names"])} />
        <.review_row label="Project" value={@attrs["project_id"]} mono />
        <.review_row label="SCM revision" value={@attrs["scm_revision"]} mono />
        <.review_row label="Update project on launch" value={fmt(@attrs["project_update_on_launch"])} />
        <.review_row label="Execution environment" value={@attrs["execution_environment_id"]} mono />
        <.review_row label="Machine credential" value={@attrs["machine_credential_id"]} mono />
        <.review_row label="Credentials" value={credentials_label(@attrs["credentials"])} />
        <.review_row label="Run mode" value={fmt(@attrs["run_mode_supported"])} />
        <.review_row label="Check mode" value={fmt(@attrs["check_mode_supported"])} />
        <.review_row label="AWX principal ID" value={@attrs["awx_created_by_id"]} mono />
        <.review_row label="Prompt: inventory" value={fmt(@attrs["ask_inventory_on_launch"])} />
        <.review_row label="Prompt: limit" value={fmt(@attrs["ask_limit_on_launch"])} />
        <.review_row label="Prompt: credentials" value={fmt(@attrs["ask_credential_on_launch"])} />
        <.review_row label="Prompt: job type" value={fmt(@attrs["ask_job_type_on_launch"])} />
        <.review_row label="Content SHA-256 (attested)" value={@attrs["content_sha256"]} mono />
        <.review_row label="Review ticket (attested)" value={@metadata["review_ticket"]} />
        <.review_row
          label="AWX snapshot digest"
          value={@attrs["reviewed_launch_snapshot_digest"]}
          mono
        />
        <.review_row label="Approval TTL (s)" value={@ttl} mono />
      </dl>

      <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
        <div>
          <p class="text-xs text-sr-muted">Input schema</p>
          <pre class="overflow-x-auto rounded-sr-control bg-sr-subtle p-2 text-xs">{fmt_json(@attrs["input_schema"])}</pre>
        </div>
        <div>
          <p class="text-xs text-sr-muted">Input classifications</p>
          <pre class="overflow-x-auto rounded-sr-control bg-sr-subtle p-2 text-xs">{fmt_json(@attrs["input_classifications"])}</pre>
        </div>
      </div>

      <p class="text-sm">
        Review digest:
        <code id="ansible-binding-review-digest" class="break-all text-xs">{@review.digest}</code>
      </p>

      <p :if={@pending == :create} id="ansible-binding-creating" class="text-sm text-sr-muted">
        Repeating the AWX reads and comparing the review digest before creating…
      </p>

      <div class="sr-ui-modal-action">
        <.ui_button
          type="button"
          size="sm"
          variant="ghost"
          disabled={@pending == :create}
          phx-click="discard_binding_review"
          data-dialog-autofocus
        >
          Discard
        </.ui_button>
        <.ui_button
          id="ansible-binding-create"
          type="button"
          size="sm"
          variant="primary"
          phx-click="create_binding"
          disabled={not is_nil(@pending)}
        >
          Create approved binding
        </.ui_button>
      </div>
    </.ui_modal>
    """
  end

  attr :binding, :map, required: true
  attr :form, :any, required: true
  attr :error, :string, default: nil

  defp revoke_modal(assigns) do
    ~H"""
    <.ui_modal id="ansible-binding-revoke-modal" size="md" on_cancel="close_revoke_binding">
      <:title>Revoke binding version</:title>

      <.ui_alert :if={@error} variant="error">{@error}</.ui_alert>

      <p class="text-sm text-sr-muted">
        Revoking version {@binding.binding_version} of template {@binding.job_template_id} stops new
        launches through it immediately. A new version needs a fresh review. This cannot be undone.
      </p>

      <.form
        for={@form}
        id="ansible-binding-revoke-form"
        phx-submit="confirm_revoke_binding"
        class="space-y-4"
      >
        <input type="hidden" name={@form[:id].name} value={@binding.id} />
        <.input
          field={@form[:confirmation_id]}
          label={"Type #{@binding.id} to confirm"}
          placeholder={to_string(@binding.id)}
          autocomplete="off"
          required
        />

        <div class="sr-ui-modal-action">
          <.ui_button type="button" phx-click="close_revoke_binding" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="danger">Revoke binding</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  ## Shared ------------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :mono, :boolean, default: false

  defp review_row(assigns) do
    ~H"""
    <div class="flex min-w-0 flex-col">
      <dt class="text-xs text-sr-muted">{@label}</dt>
      <dd class={["break-all", @mono && "font-mono text-xs"]}>{fmt(@value)}</dd>
    </div>
    """
  end

  defp membership_filters do
    [
      {"all", "All", :all},
      {"needs_review", "Needs review", :needs_review},
      {"approved", "Approved", :approved},
      {"quarantined", "Quarantined", :quarantined},
      {"unlinked", "Unlinked", :unlinked}
    ]
  end

  defp inventory_suffix(%{needs_review: count}) when count > 0, do: " (#{count} need review)"
  defp inventory_suffix(_inventory), do: ""

  defp credentials_label(credentials) when is_list(credentials) do
    Enum.map_join(credentials, ", ", fn credential ->
      "#{credential["id"]} (#{credential["kind"]})"
    end)
  end

  defp credentials_label(_credentials), do: "-"

  defp fmt(nil), do: "-"
  defp fmt(true), do: "yes"
  defp fmt(false), do: "no"
  defp fmt([]), do: "none"
  defp fmt(list) when is_list(list), do: Enum.map_join(list, ", ", &to_string/1)
  defp fmt(value), do: to_string(value)

  defp fmt_json(value) when value in [nil, %{}], do: "none"
  defp fmt_json(value), do: Jason.encode!(value, pretty: true)
end
