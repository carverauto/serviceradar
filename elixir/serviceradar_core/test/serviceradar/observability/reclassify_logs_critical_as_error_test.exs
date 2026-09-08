defmodule ServiceRadar.Observability.ReclassifyLogsCriticalAsErrorTest do
  use ExUnit.Case, async: true

  @migration_path "priv/repo/migrations/20260818180000_reclassify_logs_critical_as_error.exs"

  test "moves critical into the error bucket and leaves syslog fatal texts alone" do
    migration = File.read!(@migration_path)
    up_body = function_body!(migration, "up")
    down_body = function_body!(migration, "down")

    assert migration =~ ~s(@classifier "platform.serviceradar_log_severity_bucket")
    assert up_body =~ "CREATE OR REPLACE FUNCTION"
    assert up_body =~ "IMMUTABLE"
    refute up_body =~ "refresh_continuous_aggregate"

    {fatal_clause, rest} = clause_after(up_body, "THEN 'fatal'")
    {error_clause, _} = clause_after(rest, "THEN 'error'")

    assert fatal_clause =~ "'fatal'"
    assert fatal_clause =~ "'emergency'"
    assert fatal_clause =~ "'alert'"
    refute fatal_clause =~ "'critical'"

    assert error_clause =~ "'error'"
    assert error_clause =~ "'err'"
    assert error_clause =~ "'critical'"

    assert down_body =~ "'critical'"
    assert down_body =~ "THEN 'fatal'"
  end

  defp function_body!(source, function_name) do
    pattern = ~r/  def #{Regex.escape(function_name)}(?:\([^)]*\))? do\n(?<body>.*?)\n  end/s

    case Regex.named_captures(pattern, source) do
      %{"body" => body} -> body
      _ -> flunk("could not find #{function_name}/0 in migration source")
    end
  end

  defp clause_after(source, marker) do
    case String.split(source, marker, parts: 2) do
      [clause, rest] -> {clause, rest}
      _ -> flunk("could not find #{marker} in classifier source")
    end
  end
end
