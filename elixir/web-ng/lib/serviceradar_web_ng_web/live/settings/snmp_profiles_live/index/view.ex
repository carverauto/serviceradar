defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.CustomTemplateModal
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfileForm
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.ProfilesPanel
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.TargetModal
  import ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.Index.View.TemplateBrowserModal

  alias ServiceRadarWebNGWeb.Settings.Shell

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <Shell.settings_chrome
        current_path="/settings/snmp"
        current_scope={@current_scope}
        active_view={@settings_active_view}
        active_category={@settings_active_category}
        breadcrumbs={@settings_breadcrumbs}
        nav_tree={@settings_nav_tree}
        palette={@settings_palette}
        stats={@settings_stats}
      >
        <div class="space-y-4">
          <!-- Content based on form state -->
          <%= if @show_form in [:new_profile, :edit_profile] do %>
            <.profile_form
              form={@form}
              show_form={@show_form}
              selected_profile={@selected_profile}
              target_device_count={@target_device_count}
              target_entity={@target_entity}
              builder_open={@builder_open}
              builder={@builder}
              builder_sync={@builder_sync}
              targets={@targets}
              selected_template_ids={@selected_template_ids}
              available_templates={@available_templates}
              agents={@agents}
              snmp_credentials={@snmp_credentials}
              save_credential_as_reusable={@save_credential_as_reusable}
              credential_name={@credential_name}
            />
          <% else %>
            <.profiles_panel
              profiles={@profiles}
              profile_target_counts={@profile_target_counts}
              profile_package_names={@profile_package_names}
            />
          <% end %>
        </div>

        <!-- Target Modal -->
        <.target_modal
          :if={@show_target_modal}
          form={@target_form}
          editing_target={@editing_target}
          show_password={@show_password}
          target_oids={@target_oids}
          test_connection_result={@test_connection_result}
          test_connection_loading={@test_connection_loading}
        />

        <!-- Template Browser Modal -->
        <.template_browser_modal
          :if={@show_template_browser}
          search={@template_search}
          selected_vendor={@selected_vendor}
          custom_templates={@custom_templates}
          package_names={@template_package_names}
        />

        <!-- Custom Template Modal -->
        <.custom_template_modal
          :if={@show_custom_template_modal}
          form={@custom_template_form}
          oids={@custom_template_oids}
          editing={@editing_custom_template}
        />
      </Shell.settings_chrome>
    </Layouts.app>
    """
  end
end
