defmodule ServiceRadar.Test.CameraRelayFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwner
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionLifecycle
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.StreamProfile
  alias ServiceRadar.Repo

  require Ash.Query

  def context do
    actor = SystemActor.system(:camera_relay_test)
    key = Ecto.UUID.generate()
    opts = [actor: actor]

    {:ok, source} =
      Source.create_source(
        %{
          device_uid: "sr:relay-example-#{key}",
          vendor: "acme",
          vendor_camera_id: key,
          assigned_agent_id: "agent-example",
          assigned_gateway_id: "gateway-example"
        },
        opts
      )

    ExUnit.Callbacks.on_exit(fn -> cleanup(source.id) end)

    {:ok, profile} =
      StreamProfile.create_profile(%{camera_source_id: source.id, profile_name: "main"}, opts)

    %{source: source, profile: profile, actor: actor, opts: opts}
  end

  def open(ctx, opts \\ []) do
    defaults = [
      actor: ctx.actor,
      control_gateway_resolver: fn _agent, gateway -> {:ok, gateway} end,
      dispatch_open: fn _agent, _payload, _opts, _requester -> {:ok, Ecto.UUID.generate()} end
    ]

    RelaySessionManager.request_open(ctx.source.id, ctx.profile.id, Keyword.merge(defaults, opts))
  end

  def activate(ctx, session, ingest_id \\ Ecto.UUID.generate(), attrs \\ %{}) do
    assignment =
      Map.take(session, [:agent_id, :gateway_id, :camera_source_id, :stream_profile_id])

    RelaySessionLifecycle.activate_session(
      session.id,
      ingest_id,
      Map.merge(assignment, attrs_map(attrs)),
      ctx.opts
    )
  end

  def legacy(ctx, attrs \\ %{}) do
    defaults = %{
      camera_source_id: ctx.source.id,
      stream_profile_id: ctx.profile.id,
      agent_id: ctx.source.assigned_agent_id,
      gateway_id: ctx.source.assigned_gateway_id,
      lease_expires_at: DateTime.shift(DateTime.utc_now(), second: 30)
    }

    {:ok, session} = RelaySession.create_session(Map.merge(defaults, attrs_map(attrs)), ctx.opts)

    {:ok, session} =
      RelaySession.activate(session, %{media_ingest_id: Ecto.UUID.generate()}, ctx.opts)

    session
  end

  def owner(ctx) do
    {:ok, owner} =
      IngestOwner
      |> Ash.Query.filter(
        camera_source_id == ^ctx.source.id and stream_profile_id == ^ctx.profile.id
      )
      |> Ash.Query.load(:database_now)
      |> Ash.read_one(ctx.opts)

    owner
  end

  def expire_owner(ctx, owner) do
    owner
    |> Ash.Changeset.for_update(:transition, %{
      lease_expires_at: DateTime.shift(owner.database_now, second: -1)
    })
    |> Ash.update!(ctx.opts)
  end

  def reload(ctx, session), do: RelaySession.get_by_id(session.id, ctx.opts)

  def sessions(ctx) do
    RelaySession |> Ash.Query.filter(camera_source_id == ^ctx.source.id) |> Ash.read!(ctx.opts)
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp cleanup(source_id) do
    id = Ecto.UUID.dump!(source_id)

    Repo.query!("DELETE FROM platform.camera_recording_blocks WHERE camera_source_id = $1", [id])

    Repo.query!(
      "DELETE FROM platform.camera_recorder_claims WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM platform.camera_consumer_leases WHERE ingest_owner_id IN " <>
        "(SELECT id FROM platform.camera_ingest_owners WHERE camera_source_id = $1)",
      [id]
    )

    Repo.query!("DELETE FROM platform.camera_ingest_owners WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_relay_sessions WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_stream_profiles WHERE camera_source_id = $1", [id])
    Repo.query!("DELETE FROM platform.camera_sources WHERE id = $1", [id])

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM platform.camera_sources WHERE id = $1", [id])
  end
end
