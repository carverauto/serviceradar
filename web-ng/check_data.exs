alias ServiceRadar.Repo
require Ash.Query

IO.puts("=== Table row counts ===")
tables = %{
  "ocsf_agents" => 0,
  "ocsf_devices" => 0,
  "pollers" => 0,
  "monitoring_events" => 0,
  "service_checks" => 0,
  "alerts" => 0,
  "ng_users" => 0,
  "tenants" => 0,
  "logs" => 0
}

for {table, _} <- tables do
  case Repo.query("SELECT count(*) FROM #{table}") do
    {:ok, result} ->
      [[count]] = result.rows
      IO.puts("#{table}: #{count} rows")
    {:error, _} ->
      IO.puts("#{table}: TABLE NOT FOUND")
  end
end

IO.puts("\n=== Testing Ash query for Agents ===")
case Ash.read(ServiceRadar.Infrastructure.Agent) do
  {:ok, agents} ->
    IO.puts("Agent query succeeded: #{length(agents)} results")
  {:error, error} ->
    IO.puts("Agent query failed:")
    IO.inspect(error)
end
