defmodule ServiceRadarWebNGWeb.ControlPlaneArchiveBindingsDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.ArchiveBinding
  alias ServiceRadar.Camera.ArchiveInitAuthority
  alias ServiceRadar.Camera.ArchiveQualificationReceipt
  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  require Ash.Query

  @moduletag :web_ng_shared_fixture_db
  @moduletag sandbox: :unboxed

  @token "synthetic-binding-media-token-with-more-than-32-bytes"
  @account_token "synthetic-binding-account-token-with-more-than-32-bytes"
  @deployment_ref "703c19a0-4a11-4021-a440-000000000001"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)

    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @token, deployment_ref: @deployment_ref, generation: "1"]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)
    end)

    destination = %{
      "schema_version" => 1,
      "provisioning_ref" => "synthetic-binding-#{Ecto.UUID.generate()}",
      "generation" => 1,
      "purpose" => "recording",
      "provider" => "s3_compatible",
      "endpoint" => "https://objects.example.com",
      "region" => "example-region",
      "bucket" => "synthetic-recordings",
      "namespace" => "recordings/v1",
      "archive_format_version" => 1,
      "required_encryption" => "sse_s3_aes256"
    }

    reference = destination["provisioning_ref"]

    on_exit(fn ->
      ServiceRadar.Repo.query!(
        "DELETE FROM platform.camera_archive_bindings WHERE provisioning_ref = $1",
        [reference]
      )

      assert %{rows: [[0]]} =
               ServiceRadar.Repo.query!(
                 "SELECT count(*) FROM platform.camera_archive_bindings WHERE provisioning_ref = $1",
                 [reference]
               )
    end)

    {:ok, _} = Application.ensure_all_started(:req)
    listener = start_supervised!({Bandit, plug: ControlPlaneRuntimeRouter, scheme: :http, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    %{destination: destination, port: port, actor: SystemActor.system(:archive_binding_http_test)}
  end

  test "concurrent HTTP registration retains one unqualified identity and conflicting destinations cannot replace it",
       ctx do
    responses =
      1..3
      |> Task.async_stream(fn _ -> request(ctx.port, ctx.destination) end, max_concurrency: 3, timeout: 10_000)
      |> Enum.map(fn {:ok, response} -> response end)

    [first | retries] = responses
    assert first.status == 200
    body = first.body

    for retry <- retries do
      assert retry.status == 200
      assert retry.body == body
    end

    assert %{
             "schema_version" => 1,
             "status" => "registered",
             "binding_id" => id,
             "provisioning_ref" => reference,
             "generation" => 1,
             "destination_sha256" => digest,
             "capability_state" => "unqualified",
             "readiness" => "unavailable",
             "reason" => "archive_binding_only"
           } = body

    assert map_size(body) == 9
    assert reference == ctx.destination["provisioning_ref"]
    assert Req.Response.get_header(first, "cache-control") == ["no-store"]
    assert Req.Response.get_header(first, "x-content-type-options") == ["nosniff"]

    retry = request(ctx.port, ctx.destination)
    assert retry.status == 200
    assert retry.body == body

    conflict = request(ctx.port, %{ctx.destination | "bucket" => "different-synthetic-recordings"})
    assert conflict.status == 409
    assert conflict.body == %{"status" => "archive_binding_conflict"}

    assert [retained] = bindings(reference, ctx.actor)
    assert retained.id == id
    assert retained.destination_sha256 == digest
    assert retained.capability_state == :unqualified

    for {key, value} <- ctx.destination do
      assert Map.fetch!(retained, String.to_existing_atom(key)) == value
    end

    assert [] =
             ArchiveInitAuthority
             |> Ash.Query.filter(archive_binding_id == ^id)
             |> Ash.read!(actor: ctx.actor)

    assert [] =
             ArchiveQualificationReceipt
             |> Ash.Query.filter(archive_binding_id == ^id)
             |> Ash.read!(actor: ctx.actor)

    replacement =
      request(ctx.port, %{ctx.destination | "generation" => 2, "bucket" => "replacement-synthetic-recordings"})

    assert replacement.status == 200
    replacement_body = replacement.body
    assert replacement_body["binding_id"] != id
    assert replacement_body["generation"] == 2
    assert replacement_body["readiness"] == "unavailable"
    assert request(ctx.port, ctx.destination).body == body
  end

  defp bindings(reference, actor) do
    ArchiveBinding
    |> Ash.Query.filter(provisioning_ref == ^reference)
    |> Ash.read!(actor: actor)
  end

  defp request(port, destination) do
    Req.post!(
      "http://127.0.0.1:#{port}/v1/media/archive-bindings",
      headers: [{"content-type", "application/json"} | headers()],
      body: Jason.encode!(%{"schema_version" => 1, "destination" => destination}),
      retry: false,
      redirect: false,
      receive_timeout: 5_000
    )
  end

  defp headers do
    [
      {"x-serviceradar-control-plane-authorization", "Bearer " <> @token},
      {"x-serviceradar-deployment-ref", @deployment_ref},
      {"x-serviceradar-media-generation", "1"}
    ]
  end
end
