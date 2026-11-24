defmodule ServiceRadarNVR.Application do
  @moduledoc false
  use Application

  alias ServiceRadarNVR.Config

  @impl true
  def start(_type, _args) do
    with {:ok, config} <- Config.load(System.get_env()) do
      children = [
        {Registry, keys: :unique, name: ServiceRadarNVR.Registry},
        {ServiceRadarNVR.Capacity, config},
        {DynamicSupervisor,
         name: ServiceRadarNVR.Sessions,
         strategy: :one_for_one,
         max_children: config.max_sessions,
         extra_arguments: [config]},
        Supervisor.child_spec({Task.Supervisor, name: ServiceRadarNVR.PublicationTasks, max_children: 1},
          id: ServiceRadarNVR.PublicationTasks
        ),
        {Task.Supervisor, name: ServiceRadarNVR.ReadTasks, max_children: 4},
        Supervisor.child_spec(
          {Task.Supervisor, name: ServiceRadarNVR.PlaybackReadTasks, max_children: config.playback_read_slots},
          id: ServiceRadarNVR.PlaybackReadTasks
        ),
        Supervisor.child_spec(
          {Task.Supervisor, name: ServiceRadarNVR.AnalysisReadTasks, max_children: config.analysis_read_slots},
          id: ServiceRadarNVR.AnalysisReadTasks
        ),
        Supervisor.child_spec({Task.Supervisor, name: ServiceRadarNVR.DeliveryTasks, max_children: 1},
          id: ServiceRadarNVR.DeliveryTasks
        ),
        # One archive (and so one object-storage client) at a time per NVR.
        Supervisor.child_spec({Task.Supervisor, name: ServiceRadarNVR.ArchiveTasks, max_children: 1},
          id: ServiceRadarNVR.ArchiveTasks
        )
      ]

      scheduler = if config.auto_delivery, do: [{ServiceRadarNVR.PublicationScheduler, []}], else: []
      ingest = if config.ingest, do: [{ServiceRadarNVR.IngestListener, config}], else: []
      read = if config.read, do: [{ServiceRadarNVR.ReadListener, config}], else: []
      analysis_read = if config.analysis_read, do: [{ServiceRadarNVR.AnalysisReadListener, config}], else: []

      children =
        children ++
          scheduler ++
          ingest ++
          read ++ analysis_read ++ [{Bandit, plug: {ServiceRadarNVR.Health, config}, port: config.health_port}]

      # Losing identity or reservation accounting retires every dependent writer
      # before replacement accounting can admit work against the retained files.
      Supervisor.start_link(children, strategy: :rest_for_one, name: ServiceRadarNVR.Supervisor)
    end
  end
end
