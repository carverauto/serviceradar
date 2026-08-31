defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLive.CredentialInventoryComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.Result

  attr :loading?, :boolean, required: true
  attr :secrets, :list, required: true
  attr :focused_credential_id, :any, default: nil
  attr :integration_profiles, :map, required: true
  attr :usage_by_id, :any, required: true

  def credential_inventory_table(assigns) do
    ~H"""
    <section id="reusable-credentials" class="space-y-2 scroll-mt-24">
      <div>
        <h2 class="text-base font-semibold">Reusable Credentials</h2>
        <p class="mt-1 text-sm text-sr-muted">
          Shared credential metadata and live consumer links. Secret values are never shown.
        </p>
      </div>

      <div class="overflow-hidden rounded-lg border border-sr-line bg-sr-surface">
        <div class="sr-ui-table-shell">
          <table class={ui_table_class(size: "sm")}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Provider</th>
                <th>Type</th>
                <th>Authentication</th>
                <th>Public identity</th>
                <th>Storage</th>
                <th>Rotation</th>
                <th>Usage</th>
                <th class="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@loading?}>
                <td colspan="9" class="py-8 text-center text-sm text-sr-muted">
                  Loading reusable credentials.
                </td>
              </tr>
              <tr :if={!@loading? and @secrets == []}>
                <td colspan="9" class="py-8 text-center text-sm text-sr-muted">
                  No reusable credentials found.
                </td>
              </tr>
              <%= for secret <- @secrets do %>
                <tr
                  id={credential_dom_id(secret.id)}
                  phx-hook="CredentialDeepLinkFocus"
                  data-focused={focused_value(secret.id, @focused_credential_id)}
                  aria-current={
                    if credential_focused?(secret.id, @focused_credential_id),
                      do: "true",
                      else: nil
                  }
                  tabindex="-1"
                  class={[
                    "scroll-mt-24",
                    credential_focused?(secret.id, @focused_credential_id) &&
                      "bg-sr-brand/10 ring-1 ring-inset ring-sr-brand/30"
                  ]}
                >
                  <td>
                    <div class="font-medium">{secret.name}</div>
                    <div
                      :if={secret.description not in [nil, ""]}
                      class="mt-0.5 max-w-72 truncate text-xs text-sr-muted"
                    >
                      {secret.description}
                    </div>
                  </td>
                  <td>{provider_label(secret, @integration_profiles)}</td>
                  <td>{kind_label(secret.credential_kind)}</td>
                  <td>{auth_method_label(secret, @integration_profiles)}</td>
                  <td>{public_identity(secret)}</td>
                  <td>{source_label(secret.source_type)}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      rotation_badge_class(secret.rotation_state)
                    ]}>
                      {humanize(secret.rotation_state)}
                    </span>
                  </td>
                  <td>
                    <.credential_usage_summary
                      id={"credential-usage-#{secret.id}"}
                      usage={usage_for(@usage_by_id, secret.id)}
                    />
                  </td>
                  <td class="text-right">
                    <div id={"credential-actions-#{secret.id}"}>
                      <.ui_dropdown
                        align="end"
                        menu_class="w-48"
                        aria_label={"Actions for #{secret.name}"}
                      >
                        <:trigger>
                          <.ui_button type="button" size="xs" variant="ghost" tabindex="-1">
                            Actions
                          </.ui_button>
                        </:trigger>
                        <:item>
                          <button type="button" phx-click="edit_credential" phx-value-id={secret.id}>
                            Edit details
                          </button>
                        </:item>
                        <:item>
                          <button type="button" phx-click="rotate_credential" phx-value-id={secret.id}>
                            Rotate
                          </button>
                        </:item>
                        <:item>
                          <button type="button" phx-click="delete_credential" phx-value-id={secret.id}>
                            Delete
                          </button>
                        </:item>
                      </.ui_dropdown>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :usage, :any, required: true

  def credential_usage_summary(assigns) do
    assigns = assign(assigns, :summary, usage_summary(assigns.usage))

    ~H"""
    <div id={@id} class="min-w-44 text-sm">
      <%= case @summary do %>
        <% :unavailable -> %>
          <span class="text-sr-muted">Usage unavailable</span>
        <% :empty -> %>
          <span class="text-sr-muted">No consumers</span>
        <% {:single, summary, consumer} -> %>
          <div data-role="credential-usage-counts" class="font-medium text-sr-ink">
            {summary}
          </div>
          <.consumer_entry consumer={consumer} single?={true} />
        <% {:multiple, summary, consumers, grant_count} -> %>
          <details>
            <summary
              data-role="credential-usage-counts"
              class="cursor-pointer font-medium text-sr-brand hover:text-sr-brand-strong"
            >
              {summary}
            </summary>
            <ul class="mt-2 min-w-64 space-y-1 rounded-sr-control border border-sr-line bg-sr-raised p-2 shadow-sr-raised">
              <li :for={consumer <- consumers}>
                <.consumer_entry consumer={consumer} single?={false} />
              </li>
              <li :if={grant_count > 0} class="px-2 py-1 text-xs text-sr-muted">
                {count_label(grant_count, "active grant", "active grants")}
              </li>
            </ul>
          </details>
      <% end %>
    </div>
    """
  end

  attr :consumer, :map, required: true
  attr :single?, :boolean, required: true

  defp consumer_entry(assigns) do
    assigns =
      assigns
      |> assign(:path, consumer_path(assigns.consumer))
      |> assign(:kind_label, consumer_kind_label(assigns.consumer.kind, 1))

    ~H"""
    <%= if @path do %>
      <.link
        navigate={@path}
        class="inline-flex rounded-sr-control px-2 py-1 text-sr-brand hover:bg-sr-subtle hover:text-sr-brand-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-sr-focus"
        aria-label={consumer_accessible_label(@consumer)}
      >
        <%= if @single? do %>
          {single_consumer_label(@consumer)}
        <% else %>
          <span class="text-sr-muted">{@kind_label} ·</span>&nbsp;{@consumer.label}
        <% end %>
      </.link>
    <% else %>
      <span class="inline-flex px-2 py-1 text-sr-ink">
        <span class="text-sr-muted">{@kind_label} ·</span>&nbsp;{@consumer.label}
      </span>
    <% end %>
    """
  end

  attr :modal, :map, required: true
  attr :form, :map, required: true
  attr :descriptor, :map, default: nil
  attr :usage, :any, default: :unavailable
  attr :error, :string, default: nil

  def credential_action_modal(%{modal: %{kind: :edit}} = assigns), do: edit_modal(assigns)
  def credential_action_modal(%{modal: %{kind: :rotate}} = assigns), do: rotate_modal(assigns)
  def credential_action_modal(%{modal: %{kind: :delete}} = assigns), do: delete_modal(assigns)

  def credential_action_modal(assigns) do
    ~H"""
    """
  end

  defp edit_modal(assigns) do
    ~H"""
    <.ui_modal id="credential-edit-modal" size="form" on_cancel="close_credential_modal">
      <:title>Edit details</:title>

      <.ui_alert :if={@error} variant="error">{@error}</.ui_alert>

      <div class="grid gap-2 rounded-sr-control border border-sr-line bg-sr-subtle/60 p-3 text-xs sm:grid-cols-3">
        <div>
          <span class="block text-sr-muted">Provider</span>
          <span class="font-medium">{provider_label(@modal.secret, descriptor_profiles(@descriptor))}</span>
        </div>
        <div>
          <span class="block text-sr-muted">Authentication</span>
          <span class="font-medium">{descriptor_auth_label(@modal.secret, @descriptor)}</span>
        </div>
        <div>
          <span class="block text-sr-muted">Storage</span>
          <span class="font-medium">{source_label(@modal.secret.source_type)}</span>
        </div>
      </div>

      <.form
        for={@form}
        id="credential-edit-form"
        phx-submit="save_credential_details"
        class="space-y-4"
      >
        <input type="hidden" name={@form[:id].name} value={@modal.secret.id} />
        <.input field={@form[:name]} label="Name" required />
        <.input field={@form[:description]} type="textarea" label="Description" />

        <div class="sr-ui-modal-action">
          <.ui_button type="button" phx-click="close_credential_modal" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Save details</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  defp rotate_modal(assigns) do
    fields = descriptor_fields(assigns.descriptor)
    assigns = assign(assigns, :fields, fields)

    ~H"""
    <.ui_modal id="credential-rotate-modal" size="form" on_cancel="close_credential_modal">
      <:title>Rotate {@modal.secret.name}</:title>

      <.ui_alert :if={@error} variant="error">{@error}</.ui_alert>
      <p class="text-sm text-sr-muted">
        Enter a complete replacement. Existing credential material is never loaded into this form.
      </p>

      <.form
        for={@form}
        id="credential-rotate-form"
        phx-submit="save_credential_rotation"
        class="space-y-4"
      >
        <input type="hidden" name={@form[:id].name} value={@modal.secret.id} />

        <div class="grid gap-4 md:grid-cols-2">
          <.input
            :for={field <- @fields}
            id={"credential_rotation_fields_#{field["id"]}"}
            name={"credential_rotation[fields][#{field["id"]}]"}
            value=""
            type={descriptor_field_input_type(field)}
            label={field["label"]}
            placeholder={field["placeholder"]}
            minlength={field["min_length"]}
            maxlength={field["max_length"]}
            required={field["required"]}
            autocomplete={if(field["secret"], do: "new-password", else: "off")}
            data-credential-rotation-field
          />
        </div>

        <div class="sr-ui-modal-action">
          <.ui_button type="button" phx-click="close_credential_modal" size="sm" variant="ghost">
            Cancel
          </.ui_button>
          <.ui_button type="submit" size="sm" variant="primary">Rotate credential</.ui_button>
        </div>
      </.form>
    </.ui_modal>
    """
  end

  defp delete_modal(assigns) do
    assigns = assign(assigns, :delete_state, delete_state(assigns.usage))

    ~H"""
    <.ui_modal id="credential-delete-modal" size="md" on_cancel="close_credential_modal">
      <:title>Delete credential</:title>

      <.ui_alert :if={@error} variant="error">{@error}</.ui_alert>

      <%= case @delete_state do %>
        <% :unavailable -> %>
          <.ui_alert variant="warning">
            <p class="font-medium">Usage unavailable</p>
            <p class="mt-1 text-sm">Deletion is disabled until every consumer can be checked.</p>
          </.ui_alert>
        <% {:blocked, consumers, grant_count} -> %>
          <.ui_alert variant="warning">
            <p class="font-medium">Can't delete {@modal.secret.name}</p>
            <p class="mt-1 text-sm">
              Remove every consumer and wait for active grants to end before deleting this credential.
            </p>
          </.ui_alert>
          <ul class="space-y-1 rounded-sr-control border border-sr-line p-2">
            <li :for={consumer <- consumers}>
              <.consumer_entry consumer={consumer} single?={false} />
            </li>
            <li :if={grant_count > 0} class="px-2 py-1 text-sm text-sr-muted">
              {count_label(grant_count, "active grant", "active grants")}
            </li>
          </ul>
        <% :unused -> %>
          <p class="text-sm text-sr-muted">
            This permanently removes the credential and encrypted history owned by it. This cannot be undone.
          </p>
          <.form
            for={@form}
            id="credential-delete-form"
            phx-submit="confirm_delete_credential"
            class="space-y-4"
          >
            <input type="hidden" name={@form[:id].name} value={@modal.secret.id} />
            <.input
              field={@form[:confirmation_id]}
              label={"Type #{@modal.secret.id} to confirm"}
              placeholder={to_string(@modal.secret.id)}
              autocomplete="off"
              required
            />

            <div class="sr-ui-modal-action">
              <.ui_button
                type="button"
                phx-click="close_credential_modal"
                size="sm"
                variant="ghost"
              >
                Cancel
              </.ui_button>
              <.ui_button type="submit" size="sm" variant="danger">
                Delete permanently
              </.ui_button>
            </div>
          </.form>
      <% end %>
    </.ui_modal>
    """
  end

  defp usage_for(:unavailable, _secret_id), do: :unavailable

  defp usage_for(usage_by_id, secret_id) when is_map(usage_by_id) do
    Map.get(usage_by_id, secret_id) || Map.get(usage_by_id, to_string(secret_id)) || :unavailable
  end

  defp usage_for(_usage_by_id, _secret_id), do: :unavailable

  defp usage_summary(:unavailable), do: :unavailable

  defp usage_summary(%Result{consumers: [], live_grants: []}), do: :empty

  defp usage_summary(%Result{consumers: [consumer], live_grants: []}) do
    {:single, aggregate_usage_label([consumer], 0), consumer}
  end

  defp usage_summary(%Result{consumers: consumers, live_grants: grants}) do
    {:multiple, aggregate_usage_label(consumers, length(grants)), consumers, length(grants)}
  end

  defp usage_summary(_usage), do: :unavailable

  defp aggregate_usage_label(consumers, grant_count) do
    counts = Enum.frequencies_by(consumers, & &1.kind)

    {profile_and_rule_labels, remaining_counts} =
      if Map.has_key?(counts, :snmp_profile) or Map.has_key?(counts, :credential_rule) do
        {[
           count_label(Map.get(counts, :snmp_profile, 0), "SNMP profile", "SNMP profiles"),
           count_label(Map.get(counts, :credential_rule, 0), "rule", "rules")
         ], Map.drop(counts, [:snmp_profile, :credential_rule])}
      else
        {[], counts}
      end

    other_consumer_labels =
      remaining_counts
      |> Enum.sort_by(fn {kind, _count} -> to_string(kind) end)
      |> Enum.map(fn {kind, count} -> consumer_kind_label(kind, count) end)

    Enum.join(
      profile_and_rule_labels ++
        other_consumer_labels ++
        if(grant_count > 0, do: [count_label(grant_count, "active grant", "active grants")], else: []),
      " · "
    )
  end

  defp single_consumer_label(%Consumer{kind: kind, label: label}) do
    "#{consumer_kind_label(kind, 1)} · #{label}"
  end

  defp consumer_kind_label(:snmp_profile, count), do: count_label(count, "SNMP profile", "SNMP profiles")

  defp consumer_kind_label(:credential_rule, count), do: count_label(count, "credential rule", "credential rules")

  defp consumer_kind_label(kind, count) do
    label = kind |> humanize() |> String.downcase()
    count_label(count, label, "#{label}s")
  end

  defp count_label(1, singular, _plural), do: "1 #{singular}"
  defp count_label(count, _singular, plural), do: "#{count} #{plural}"

  defp consumer_path(%Consumer{kind: :snmp_profile, id: id}), do: ~p"/settings/snmp/#{id}/edit"

  defp consumer_path(%Consumer{kind: :credential_rule, id: id}), do: ~p"/settings/networks/credentials/#{id}/edit"

  defp consumer_path(_consumer), do: nil

  defp consumer_accessible_label(%Consumer{kind: :snmp_profile, label: label}), do: "Edit SNMP profile #{label}"

  defp consumer_accessible_label(%Consumer{kind: :credential_rule, label: label}), do: "Edit credential rule #{label}"

  defp consumer_accessible_label(%Consumer{label: label}), do: label

  defp delete_state(:unavailable), do: :unavailable

  defp delete_state(%Result{consumers: [], live_grants: []}), do: :unused

  defp delete_state(%Result{consumers: consumers, live_grants: grants}), do: {:blocked, consumers, length(grants)}

  defp delete_state(_usage), do: :unavailable

  defp descriptor_profiles(%{profile: %{} = profile}), do: %{to_string(profile["provider"]) => profile}

  defp descriptor_profiles(_descriptor), do: %{}

  defp descriptor_fields(%{method: %{"fields" => fields}}) when is_list(fields), do: fields
  defp descriptor_fields(_descriptor), do: []

  defp descriptor_auth_label(_secret, %{method: %{"label" => label}}) when is_binary(label) and label != "", do: label

  defp descriptor_auth_label(secret, _descriptor), do: auth_method_label(secret, %{})

  defp descriptor_field_input_type(%{"control" => "textarea"}), do: "textarea"
  defp descriptor_field_input_type(%{"control" => "password"}), do: "password"
  defp descriptor_field_input_type(%{"secret" => true}), do: "password"
  defp descriptor_field_input_type(_field), do: "text"

  defp credential_dom_id(id), do: "credential-secret-#{id}"

  defp focused_value(secret_id, focused_id), do: if(credential_focused?(secret_id, focused_id), do: "true", else: "false")

  defp credential_focused?(_secret_id, focused_id) when focused_id in [nil, ""], do: false

  defp credential_focused?(secret_id, focused_id), do: to_string(secret_id) == to_string(focused_id)

  defp provider_label(secret, integration_profiles) do
    case Map.get(integration_profiles, to_string(secret.provider)) do
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> to_string(secret.provider)
    end
  end

  defp auth_method_label(secret, integration_profiles) do
    auth_method =
      secret
      |> Map.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.get("auth_method")

    profile = Map.get(integration_profiles, to_string(secret.provider))

    case method_descriptor(profile, auth_method) do
      %{"label" => label} when is_binary(label) and label != "" -> label
      _ -> auth_method_fallback(auth_method)
    end
  end

  defp method_descriptor(%{"auth_methods" => methods}, auth_method) when is_list(methods),
    do: Enum.find(methods, &(to_string(&1["id"]) == to_string(auth_method)))

  defp method_descriptor(_profile, _auth_method), do: nil

  defp auth_method_fallback(value) when value in [nil, ""], do: "—"
  defp auth_method_fallback("api_token"), do: "API token"
  defp auth_method_fallback("v3"), do: "SNMPv3 user"
  defp auth_method_fallback("community"), do: "Community string"
  defp auth_method_fallback(value), do: humanize(value)

  defp kind_label(:api_token), do: "API token"
  defp kind_label(:snmp), do: "SNMP"
  defp kind_label(value), do: humanize(value)

  defp public_identity(%{username: username}) when is_binary(username) and username != "", do: username

  defp public_identity(%{credential_kind: :ssh_private_key, public_fingerprint: fingerprint})
       when is_binary(fingerprint) and fingerprint != "", do: fingerprint

  defp public_identity(_secret), do: "—"

  defp source_label(:internal_encrypted), do: "Encrypted here"
  defp source_label(:external_reference), do: "External reference"
  defp source_label(value), do: humanize(value)

  defp rotation_badge_class(:active), do: "badge-success"
  defp rotation_badge_class(:rotation_due), do: "badge-warning"
  defp rotation_badge_class(:rotation_failed), do: "badge-error"
  defp rotation_badge_class(:rotating), do: "badge-info"
  defp rotation_badge_class(_value), do: "badge-ghost"

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp humanize(nil), do: "—"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
