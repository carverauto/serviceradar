defmodule ServiceRadarCoreElx.CameraRecording.Supervisor do
  @moduledoc "Node-local supervision for explicitly enabled, independently leased recorders."
  use Supervisor

  alias ServiceRadarCoreElx.CameraRecording.ContinuousManager
  alias ServiceRadarCoreElx.CameraRecording.ContinuousRecorder
  alias ServiceRadarCoreElx.CameraRecording.ContinuousWorkers
  alias ServiceRadarCoreElx.CameraRecording.NVRWorker
  alias ServiceRadarCoreElx.CameraRecording.Worker
  alias ServiceRadarCoreElx.CameraRecording.Workers

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def enabled?, do: Application.get_env(:serviceradar_core_elx, :camera_recording_enabled, false) == true

  def start_recorder(opts) do
    if enabled?(),
      do: DynamicSupervisor.start_child(Workers, {Worker, opts}),
      else: {:error, :recording_disabled}
  end

  def start_nvr_recorder(opts) do
    if enabled?(),
      do: DynamicSupervisor.start_child(Workers, {NVRWorker, opts}),
      else: {:error, :recording_disabled}
  end

  def start_continuous_recorder(opts) do
    if enabled?(),
      do: DynamicSupervisor.start_child(ContinuousWorkers, {ContinuousRecorder, opts}),
      else: {:error, :recording_disabled}
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: ServiceRadarCoreElx.CameraRecording.Registry},
        {DynamicSupervisor, strategy: :one_for_one, max_children: 4, name: Workers},
        {DynamicSupervisor, strategy: :one_for_one, name: ContinuousWorkers},
        ContinuousManager
      ],
      strategy: :rest_for_one
    )
  end
end
