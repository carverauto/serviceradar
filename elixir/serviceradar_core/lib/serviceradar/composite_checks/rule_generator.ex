defmodule ServiceRadar.CompositeChecks.RuleGenerator do
  @moduledoc """
  Seeds a decision table from vantage point expectations.

  Generation is an authoring convenience only. The evaluator never reads
  `expected`; once rules exist they are the sole source of evaluation semantics
  and may be edited freely. Regenerating warns before discarding edits.

  The generated table covers the four cases two vantage points can produce, and
  splits the expected case on a boolean fact when one is declared:

    * expected pattern + fact true  -> isolated_verified     (healthy)
    * expected pattern + fact false -> isolated_unenforced   (degraded)
    * both reachable                -> not_isolated          (down)
    * neither reachable             -> device_unreachable    (degraded)
    * inverted                      -> inverted_reachability (down)

  Anything not covered falls through to the check's catch-all. Note that
  "neither reachable" is deliberately `degraded` rather than `healthy`: a
  powered-off device is unreachable from every vantage point, and counting that
  as compliant is exactly the failure the liveness witness exists to prevent.
  """

  @spec generate([struct()]) :: [map()]
  def generate(inputs) when is_list(inputs) do
    vantage_points = Enum.filter(inputs, &(&1.kind == :vantage_point))

    witness = Enum.find(vantage_points, &(&1.expected == "available"))
    probe = Enum.find(vantage_points, &(&1.expected == "blocked"))

    if witness && probe do
      fact = Enum.find(inputs, &(&1.kind == :device_metadata))

      witness.key
      |> rows(probe.key, fact)
      |> Enum.with_index()
      |> Enum.map(fn {row, index} -> Map.put(row, :position, index) end)
    else
      []
    end
  end

  defp rows(witness_key, probe_key, nil) do
    [
      row(
        %{witness_key => "available", probe_key => "blocked"},
        "isolated_verified",
        :healthy,
        "Isolation observed from every vantage point that should not reach it"
      ),
      not_isolated(witness_key, probe_key),
      device_unreachable(witness_key, probe_key),
      inverted(witness_key, probe_key)
    ]
  end

  defp rows(witness_key, probe_key, fact) do
    [
      row(
        %{witness_key => "available", probe_key => "blocked", fact.key => true},
        "isolated_verified",
        :healthy,
        "Isolation observed, and the config that enforces it is in place"
      ),
      row(
        %{witness_key => "available", probe_key => "blocked", fact.key => false},
        "isolated_unenforced",
        :degraded,
        "Blocked today, but not by device config - likely an upstream ACL that could change"
      ),
      not_isolated(witness_key, probe_key),
      device_unreachable(witness_key, probe_key),
      inverted(witness_key, probe_key)
    ]
  end

  defp not_isolated(witness_key, probe_key) do
    row(
      %{witness_key => "available", probe_key => "available"},
      "not_isolated",
      :down,
      "Reachable from a network that should be fenced off"
    )
  end

  defp device_unreachable(witness_key, probe_key) do
    row(
      %{witness_key => "blocked", probe_key => "blocked"},
      "device_unreachable",
      :degraded,
      "Nobody can see it - the device is probably down, so isolation cannot be proven either way"
    )
  end

  defp inverted(witness_key, probe_key) do
    row(
      %{witness_key => "blocked", probe_key => "available"},
      "inverted_reachability",
      :down,
      "The wrong network has access and the right one does not - check routing or agent placement"
    )
  end

  defp row(match, verdict, status, description) do
    %{
      match: match,
      verdict: verdict,
      verdict_label: verdict |> String.replace("_", " ") |> String.capitalize(),
      verdict_description: description,
      status: status
    }
  end
end
