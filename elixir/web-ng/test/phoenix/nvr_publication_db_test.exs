defmodule ServiceRadarWebNGWeb.NVRPublicationDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Camera.LocalPublicationIntent
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Repo
  alias ServiceRadar.Test.CameraRelayFixtures, as: Fixtures
  alias ServiceRadarWebNG.NVRPublicationHTTP, as: HTTP

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    recovery = Fixtures.publication_recovery_gate(directory)
    Fixtures.preserve_recording_control()
    ctx = Fixtures.context()
    {:ok, relay} = Fixtures.open(ctx)
    {:ok, relay} = Fixtures.activate(ctx, relay)
    owner = Fixtures.owner(ctx)

    {:ok, claim} =
      RecorderOwnership.acquire(
        owner,
        Ecto.UUID.generate(),
        relay.media_ingest_id,
        Ecto.UUID.generate(),
        30_000,
        ctx.opts
      )

    clock = %{
      "clock_epoch" => "synthetic-http-clock",
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    {:ok, block} = RecorderOwnership.reserve_block(owner, claim, clock, ctx.opts)
    server = directory |> HTTP.installation(block.storage_id) |> HTTP.start!()
    Map.merge(ctx, %{owner: owner, claim: claim, block: block, server: server, recovery: recovery})
  end

  test "lost replies replay the committed canonical acknowledgement across listener restart", ctx do
    assert {:ok, frozen} = freeze(ctx)
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)
    socket = HTTP.send_without_reading(ctx.server, bytes)
    on_exit(fn -> :ssl.close(socket) end)
    # Observe the committed receipt independently without consuming the HTTP reply.
    persisted = await_receipt(operation, ctx.opts, System.monotonic_time(:millisecond) + 5_000)
    :ok = :ssl.close(socket)
    stop_supervised!(ctx.server.child_id)
    server = HTTP.start!(ctx.server)

    File.write!(ctx.recovery.path, String.replace(ctx.recovery.ready, "ready", "closed"))
    assert {:ok, %{status: 503, body: unavailable}} = HTTP.request(server, bytes)
    assert Jason.decode!(unavailable) == %{"error" => "publication_unavailable"}
    File.write!(ctx.recovery.path, ctx.recovery.ready)

    assert {:ok, %{status: 200, body: acknowledgement, headers: headers}} = HTTP.request(server, bytes)

    assert Jason.decode!(acknowledgement) == %{
             "version" => 1,
             "kind" => "intent_accepted",
             "operation_id" => operation,
             "intent_sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
           }

    assert headers["cache-control"] == ["no-store"]
    assert {:ok, %{status: 200, body: ^acknowledgement}} = HTTP.request(server, bytes)
    assert {:ok, retry} = Ash.get(LocalPublicationIntent, operation, Keyword.put(ctx.opts, :not_found_error?, false))
    assert retry.inserted_at == persisted.inserted_at
    assert retry.recording_block_id == frozen.id
    assert {:ok, original} = Ash.get(RecordingBlock, frozen.id, ctx.opts)
    assert original.state == :sealed
    assert is_nil(original.archive_published_at)
    assert is_nil(original.archive_binding_id)
    assert is_nil(original.upload_token)
  end

  test "installed storage binding and frozen authority both constrain the authenticated request", ctx do
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)
    assert {:ok, %{status: 409}} = HTTP.request(ctx.server, bytes)
    assert {:ok, _} = freeze(ctx)
    changed = %{ctx.block | storage_id: Ecto.UUID.generate()}
    assert {:ok, %{status: 403}} = HTTP.request(ctx.server, Fixtures.local_intent(changed, operation))
    assert {:ok, nil} = Ash.get(LocalPublicationIntent, operation, Keyword.put(ctx.opts, :not_found_error?, false))

    # Rebind the same trusted certificate: claiming its new UUID still cannot
    # substitute for the original frozen block's storage lifetime.
    document =
      Map.update!(ctx.server.document, "clients", fn clients ->
        Map.new(clients, fn {pin, _} -> {pin, changed.storage_id} end)
      end)

    File.write!(ctx.server.opts[:config_file], Jason.encode!(document))
    rebound = HTTP.start!(ctx.server)
    assert {:ok, %{status: 403}} = HTTP.request(rebound, bytes)
    assert {:ok, %{status: 409}} = HTTP.request(rebound, Fixtures.local_intent(changed, operation))
    assert {:ok, nil} = Ash.get(LocalPublicationIntent, operation, Keyword.put(ctx.opts, :not_found_error?, false))

    assert {:ok, %{status: 200}} = HTTP.request(ctx.server, bytes)
    assert {:ok, %{status: 409}} = HTTP.request(ctx.server, Fixtures.local_intent(ctx.block, Ecto.UUID.generate()))
  end

  test "absolute request deadline closes a DB-blocked connection without later accepting its intent", ctx do
    assert {:ok, _} = freeze(ctx)
    parent = self()

    locker =
      Task.async(fn ->
        Repo.transaction(
          fn ->
            Repo.query!(
              "SELECT id FROM platform.camera_recording_blocks WHERE id = $1 FOR UPDATE",
              [Ecto.UUID.dump!(ctx.block.id)]
            )

            send(parent, :block_locked)

            receive do
              :release -> :ok
            after
              20_000 -> raise "lock release deadline exceeded"
            end
          end,
          timeout: 25_000
        )
      end)

    on_exit(fn -> send(locker.pid, :release) end)
    assert_receive :block_locked, 5_000
    operation = Ecto.UUID.generate()
    bytes = Fixtures.local_intent(ctx.block, operation)
    socket = HTTP.send_without_reading(ctx.server, bytes)
    on_exit(fn -> :ssl.close(socket) end)
    assert {:error, :closed} = :ssl.recv(socket, 0, 13_000)
    send(locker.pid, :release)
    assert {:ok, :ok} = Task.await(locker, 5_000)
    assert {:ok, nil} = Ash.get(LocalPublicationIntent, operation, Keyword.put(ctx.opts, :not_found_error?, false))
    assert {:ok, %{status: 200}} = HTTP.request(ctx.server, bytes)
  end

  defp freeze(ctx),
    do: RecordingBlocks.freeze(ctx.owner, ctx.claim, ctx.block, Fixtures.recording_descriptor(ctx.block), ctx.opts)

  defp await_receipt(operation, opts, deadline) do
    case Ash.get(LocalPublicationIntent, operation, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %LocalPublicationIntent{} = receipt} ->
        receipt

      {:ok, nil} ->
        assert System.monotonic_time(:millisecond) < deadline, "intent never committed"

        receive do
        after
          25 -> await_receipt(operation, opts, deadline)
        end

      other ->
        flunk("receipt read failed: #{inspect(other)}")
    end
  end
end
