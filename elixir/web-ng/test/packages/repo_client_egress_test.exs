defmodule ServiceRadarWebNG.Packages.RepoClientEgressTest do
  @moduledoc """
  Guards that `ServiceRadarWebNG.Packages.RepoClient` routes all external HTTP
  through the configured client (EgressClient by default) and never calls `Req`
  directly.

  The guard works by injecting a stub that records every `fetch_body/2` call and
  asserting the stub is invoked. If any code path inside `RepoClient` bypassed
  the injection and called `Req.get/2` directly, it would attempt a real network
  connection in CI and fail -- making the bypass visible rather than silent.
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Packages.RepoClient

  @moduletag :db_free

  defmodule RecordingClient do
    @moduledoc false

    def fetch_body(url, _opts) do
      send(self(), {:fetch_body_called, url})

      cond do
        String.contains?(url, "api.github.com/repos/acme/demo") and
            not String.contains?(url, "/commits/") ->
          {:ok, %Req.Response{status: 200, body: %{"default_branch" => "main"}, headers: %{}}}

        String.contains?(url, "api.github.com/repos/acme/demo/commits/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "sha" => String.duplicate("b", 40),
               "commit" => %{"verification" => %{"verified" => false, "reason" => "unsigned"}}
             },
             headers: %{}
           }}

        String.contains?(url, "raw.githubusercontent.com/acme/demo") ->
          {:ok, %Req.Response{status: 200, body: "# synthetic fixture", headers: %{}}}

        String.contains?(url, "api.github.com/repos/acme/demo/releases/tags/") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"tag_name" => "v1.0.0", "assets" => []},
             headers: %{}
           }}

        String.contains?(url, "api.github.com/repos/acme/demo/releases") ->
          {:ok, %Req.Response{status: 200, body: [], headers: %{}}}

        true ->
          {:ok, %Req.Response{status: 404, body: "", headers: %{}}}
      end
    end
  end

  setup do
    repo = %{owner: "acme", repo: "demo"}
    opts = [http_client: RecordingClient]
    %{repo: repo, opts: opts}
  end

  test "resolve_ref routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, %{sha: sha}} = RepoClient.resolve_ref(repo, "main", opts)
    assert sha == String.duplicate("b", 40)

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
  end

  test "fetch_raw routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, body} = RepoClient.fetch_raw(repo, "main", "README.md", opts)
    assert body == "# synthetic fixture"

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "raw.githubusercontent.com")
  end

  test "fetch_release routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, release} = RepoClient.fetch_release(repo, "v1.0.0", opts)
    assert release["tag_name"] == "v1.0.0"

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
    assert String.contains?(url, "/releases/tags/")
  end

  test "fetch_recent_releases routes through the injected client, not Req", %{repo: repo, opts: opts} do
    assert {:ok, releases} = RepoClient.fetch_recent_releases(repo, 5, opts)
    assert is_list(releases)

    assert_received {:fetch_body_called, url}
    assert String.contains?(url, "api.github.com")
    assert String.contains?(url, "/releases")
  end
end
