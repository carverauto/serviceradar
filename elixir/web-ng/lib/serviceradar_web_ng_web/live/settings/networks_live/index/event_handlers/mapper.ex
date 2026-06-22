defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.Index.EventHandlers.Mapper do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Data
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.Formatting
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperForms
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperParams
  import ServiceRadarWebNGWeb.Settings.NetworksLive.Index.MapperPersistence

  def handle_event("save_mapper_job", params, socket) do
    scope = socket.assigns.current_scope
    job_params = normalize_mapper_job_params(Map.get(params, "mapper_job", %{}))
    seeds = parse_seeds_text(Map.get(params, "seeds", ""))
    unifi_params = normalize_unifi_params(Map.get(params, "unifi", %{}))
    mikrotik_params = normalize_mikrotik_params(Map.get(params, "mikrotik", %{}))

    case save_mapper_job(
           socket.assigns.mapper_job,
           job_params,
           seeds,
           unifi_params,
           mikrotik_params,
           scope
         ) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:mapper_jobs, load_mapper_jobs(scope))
         |> put_flash(:info, "Discovery job saved")
         |> push_navigate(to: ~p"/settings/networks/discovery")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save discovery job: #{format_error(reason)}")}
    end
  end

  def handle_event("mapper_form_change", params, socket) do
    # Update the form with changed values to trigger conditional rendering
    job_params = Map.get(params, "mapper_job", %{})
    seeds_text = Map.get(params, "seeds", socket.assigns.mapper_seeds_text)

    # Merge changed params into existing form
    current_form_data = socket.assigns.mapper_form.source
    updated_form_data = Map.merge(current_form_data, job_params)
    updated_form = to_form(updated_form_data, as: :mapper_job)

    mikrotik =
      build_mikrotik_fields_from_params(
        Map.get(socket.assigns, :mapper_mikrotik, empty_mikrotik_fields()),
        Map.get(params, "mikrotik", %{})
      )

    {:noreply,
     socket
     |> assign(:mapper_form, updated_form)
     |> assign(:mapper_seeds_text, seeds_text)
     |> assign(:mapper_mikrotik, mikrotik)}
  end
end
