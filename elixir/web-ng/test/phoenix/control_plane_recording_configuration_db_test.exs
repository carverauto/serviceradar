defmodule ServiceRadarWebNGWeb.ControlPlaneRecordingConfigurationDBTest do
  use ServiceRadarWebNG.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNGWeb.ControlPlaneRuntimeRouter

  @moduletag :web_ng_shared_fixture_db

  @token "synthetic-recording-control-token-for-http-test"
  @account_token "synthetic-recording-account-token-for-http-test"
  @header "x-serviceradar-control-plane-authorization"
  @deployment_header "x-serviceradar-deployment-ref"
  @generation_header "x-serviceradar-media-generation"

  setup do
    previous = Application.get_env(:serviceradar_web_ng, :control_plane_runtime)
    installation = %{deployment_ref: Ecto.UUID.generate(), generation: "1"}
    install(installation)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:serviceradar_web_ng, :control_plane_runtime, previous),
        else: Application.delete_env(:serviceradar_web_ng, :control_plane_runtime)
    end)

    %{installation: installation}
  end

  test "private HTTP persists an origin-bound stop without advertising readiness", %{installation: installation} do
    document = %{"contract_version" => 1, "revision" => "1", "admission" => "stopped"}
    body = Jason.encode!(document)
    baseline = request(:get, installation)
    assert baseline.status == 200
    assert %{"stop_enforced" => false, "desired_revision" => nil} = decode(baseline)

    rejected = request(:put, installation, body, @account_token)
    assert rejected.status == 401
    assert decode(request(:get, installation)) == decode(baseline)

    stopped = request(:put, installation, body)
    assert stopped.status == 200
    projection = decode(stopped)

    assert %{
             "contract_version" => 1,
             "stop_enforced" => true,
             "desired_revision" => "1",
             "desired_digest" => digest,
             "received_at" => received_at,
             "applied_revision" => nil,
             "readiness" => "unavailable",
             "reason" => "recording_stop_only",
             "drain_status" => "not_attested"
           } = projection

    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert {:ok, _, 0} = DateTime.from_iso8601(received_at)
    assert get_resp_header(stopped, "cache-control") == ["no-store"]
    assert get_resp_header(stopped, "x-content-type-options") == ["nosniff"]
    refute stopped.resp_body =~ @token
    refute stopped.resp_body =~ installation.deployment_ref

    retry = request(:put, installation, body)
    assert retry.status == 200
    assert decode(retry) == projection
    assert decode(request(:get, installation)) == projection

    resume = request(:put, installation, Jason.encode!(%{document | "revision" => "2", "admission" => "enabled"}))
    assert resume.status == 400
    assert decode(resume) == %{"status" => "invalid_recording_configuration"}
    assert decode(request(:get, installation)) == projection

    replacement = %{installation | generation: "2"}
    install(replacement)
    assert request(:get, installation).status == 401

    conflict = request(:put, replacement, body)
    assert conflict.status == 409
    assert decode(conflict) == %{"status" => "recording_revision_conflict"}
    assert decode(request(:get, replacement)) == projection

    newer = request(:put, replacement, Jason.encode!(%{document | "revision" => "2"}))
    assert newer.status == 200
    assert %{"stop_enforced" => true, "desired_revision" => "2"} = decode(newer)
    refute decode(newer)["desired_digest"] == digest

    stale = request(:put, replacement, body)
    assert stale.status == 409
    assert decode(stale) == %{"status" => "recording_revision_stale"}

    # An old process can authenticate its own installation but cannot overwrite
    # the durable stop that a newer installation has acknowledged.
    install(installation)
    old_process = request(:put, installation, Jason.encode!(%{document | "revision" => "3"}))
    assert old_process.status == 409
    assert decode(old_process) == %{"status" => "recording_generation_stale"}

    install(replacement)
    assert decode(request(:get, replacement)) == decode(newer)
  end

  defp request(method, installation, body \\ "", token \\ @token) do
    method
    |> conn("/v1/media/configuration", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header(@header, "Bearer " <> token)
    |> put_req_header(@deployment_header, installation.deployment_ref)
    |> put_req_header(@generation_header, installation.generation)
    |> ControlPlaneRuntimeRouter.call([])
  end

  defp install(installation) do
    Application.put_env(:serviceradar_web_ng, :control_plane_runtime,
      token: @account_token,
      media: [token: @token, deployment_ref: installation.deployment_ref, generation: installation.generation]
    )
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
