defmodule ServiceRadarWebNG.ReportSourceStub do
  @moduledoc """
  Stand-in for `ServiceRadar.HTTP.EgressClient` in report import tests.

  Serves exact URLs from a route map held in application env, so a request made
  from a LiveView async task sees the same routes as the test process. Any URL
  not in the map is a 404, and every request is reported to the installing test
  process as `{:report_source_stub_request, url}` so a test can assert that a
  refused import fetched nothing.
  """

  @env_key :report_source_stub

  @doc "Installs `routes` (URL => body map or binary) and routes GitHub import traffic here."
  def install(routes) when is_map(routes) do
    previous_client = Application.get_env(:serviceradar_web_ng, :github_http_client)
    Application.put_env(:serviceradar_web_ng, @env_key, %{routes: routes, owner: self()})
    Application.put_env(:serviceradar_web_ng, :github_http_client, __MODULE__)

    fn ->
      Application.delete_env(:serviceradar_web_ng, @env_key)

      if previous_client,
        do: Application.put_env(:serviceradar_web_ng, :github_http_client, previous_client),
        else: Application.delete_env(:serviceradar_web_ng, :github_http_client)
    end
  end

  def fetch_body(url, _opts) do
    %{routes: routes, owner: owner} = Application.fetch_env!(:serviceradar_web_ng, @env_key)
    send(owner, {:report_source_stub_request, url})

    case Map.fetch(routes, url) do
      {:ok, body} -> {:ok, %Req.Response{status: 200, body: body}}
      :error -> {:ok, %Req.Response{status: 404, body: ""}}
    end
  end

  def commit_url(owner, repo, ref),
    do: "https://api.github.com/repos/#{owner}/#{repo}/commits/#{URI.encode_www_form(ref)}"

  def raw_url(owner, repo, sha, path), do: "https://raw.githubusercontent.com/#{owner}/#{repo}/#{sha}/#{path}"

  def commit_body(sha, verified?) do
    verification =
      if verified?,
        do: %{"verified" => true, "reason" => "valid", "signer" => %{"login" => "release-bot"}},
        else: %{"verified" => false, "reason" => "unsigned"}

    %{"sha" => sha, "commit" => %{"verification" => verification}}
  end

  @doc "A valid one-panel report definition with the given slug and query."
  def definition(slug, query \\ "in:devices limit:10") do
    Jason.encode!(%{
      "version" => 1,
      "slug" => slug,
      "title" => "Report #{slug}",
      "description" => "Synthetic report for import tests.",
      "default_time_range" => "last_24h",
      "metadata" => %{"system_report" => true},
      "panels" => [
        %{
          "title" => "Devices",
          "srql_query" => query,
          "visual_type" => "table",
          "data_binding" => %{},
          "layout" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 6},
          "position" => 0
        }
      ]
    })
  end

  @doc "A report index body listing `entries` as `{slug, path, enabled_by_default}`."
  def index(entries) do
    Jason.encode!(%{
      "version" => 1,
      "reports" =>
        Enum.map(entries, fn {slug, path, enabled} ->
          %{"slug" => slug, "path" => path, "enabled_by_default" => enabled}
        end)
    })
  end
end
