defmodule ServiceRadarWebNG.Mcp.IdentityDiagnostics do
  @moduledoc """
  Task-oriented identity diagnostics for MCP, composed from bound SRQL.

  Everything here runs through the same `Api.Access.execute_query/2` path as the
  `execute_srql` tool, so the `devices.view` entity gate and the projection
  redaction rules apply once rather than once per caller. The alternative --
  reading `ServiceRadar.Inventory` resources directly -- would give web-ng a
  second route into core identity internals that has to re-implement both.

  Read-only. No merge, unmerge, delete or restore is reachable from here.
  """

  alias ServiceRadarWebNG.Api.Access
  alias ServiceRadarWebNG.Mcp.SrqlBind

  @default_rows 50
  @max_rows 200
  @default_runs 10

  @doc """
  Trace one device's identity: current record, tombstone, merge chain both
  directions, revivals, identifiers with their currency, and evidence edges.

  `seed` may be a device uid, an IP, or a hostname; a non-uid seed is resolved
  through a bound device query that includes tombstoned devices, because the
  device an operator is asking about has often just been tombstoned.
  """
  @spec trace(map(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def trace(scope, seed, opts \\ []) when is_binary(seed) do
    row_limit = SrqlBind.clamp(opts[:limit], @default_rows, @max_rows)

    with {:ok, uid, resolution} <- resolve_seed(scope, seed),
         {:ok, literal} <- SrqlBind.literal(uid, :device_uid),
         {:ok, device} <- device_row(scope, literal),
         {:ok, chain} <- rows(scope, "in:merge_audit chain:#{literal} limit:#{row_limit}"),
         {:ok, revivals} <-
           rows(scope, "in:device_revival_audit device_uid:#{literal} limit:#{row_limit}"),
         {:ok, identifiers} <-
           rows(scope, "in:device_identifiers device_id:#{literal} limit:#{row_limit}"),
         {:ok, evidence} <-
           rows(scope, "in:identity_evidence_edges device:#{literal} limit:#{row_limit}") do
      {:ok,
       annotate_trace(%{
         "device_uid" => uid,
         "seed" => seed,
         "seed_resolution" => resolution,
         "device" => device,
         "merge_chain" => chain,
         "revivals" => revivals,
         "identifiers" => identifiers,
         "evidence" => evidence
       })}
    end
  end

  # A tombstoned device is the usual subject here, so ask for it first.
  defp device_row(scope, literal) do
    case rows(scope, "in:devices uid:#{literal} deleted:true limit:1") do
      {:ok, [row | _]} -> {:ok, row}
      {:ok, []} -> first_or_nil(rows(scope, "in:devices uid:#{literal} limit:1"))
      error -> error
    end
  end

  defp first_or_nil({:ok, [row | _]}), do: {:ok, row}
  defp first_or_nil({:ok, []}), do: {:ok, nil}
  defp first_or_nil(error), do: error

  @doc """
  Summarise reconciliation runs, including whether each stopped at its cap.

  With `run_id`, returns that one run and the evidence edges for each blocked
  component it recorded. Without one, returns the most recent runs in the
  window.
  """
  @spec explain(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def explain(scope, opts \\ []) do
    limit = SrqlBind.clamp(opts[:limit], @default_runs, @max_rows)
    time = time_token(opts[:time])

    with {:ok, query} <- runs_query(opts[:run_id], time, limit),
         {:ok, runs} <- rows(scope, query),
         {:ok, evidence} <- blocked_evidence(scope, runs, opts) do
      payload = %{
        "runs" => Enum.map(runs, &summarise_run/1),
        "run_count" => length(runs)
      }

      {:ok,
       case evidence do
         nil -> payload
         edges -> Map.put(payload, "blocked_component_evidence", edges)
       end}
    end
  end

  # -- seed resolution -------------------------------------------------------

  defp resolve_seed(scope, seed) do
    case SrqlBind.classify(seed) do
      :device_uid ->
        {:ok, String.trim(seed), "uid"}

      kind when kind in [:ip, :hostname] ->
        resolve_by(scope, seed, kind)

      :unknown ->
        {:error, "#{inspect(seed)} is not a device uid, IP, or hostname. Pass a uid like sr:<uuid>."}
    end
  end

  defp resolve_by(scope, seed, kind) do
    field = if kind == :ip, do: "ip", else: "hostname"

    # deleted:true so a device that was just tombstoned is still findable --
    # which is the case an operator is usually in when they reach for this.
    with {:ok, literal} <- SrqlBind.literal(seed, kind),
         {:ok, tombstoned} <- rows(scope, "in:devices #{field}:#{literal} deleted:true limit:5"),
         {:ok, live} <- rows(scope, "in:devices #{field}:#{literal} limit:5") do
      case Enum.uniq_by(tombstoned ++ live, &Map.get(&1, "uid")) do
        [] ->
          {:error, "no device found with #{field} #{seed} (searched live and tombstoned)"}

        [one] ->
          {:ok, Map.get(one, "uid"), "resolved by #{field}"}

        many ->
          uids = many |> Enum.map(&Map.get(&1, "uid")) |> Enum.reject(&is_nil/1)

          {:error,
           "#{field} #{seed} matches #{length(many)} devices (#{Enum.join(uids, ", ")}); " <>
             "pass one uid explicitly"}
      end
    end
  end

  # -- reconciliation runs ---------------------------------------------------

  defp runs_query(nil, time, limit) do
    {:ok, "in:identity_reconciliation_runs #{time} limit:#{limit}"}
  end

  defp runs_query(run_id, _time, _limit) do
    with {:ok, literal} <- SrqlBind.literal(run_id, :uuid) do
      {:ok, "in:identity_reconciliation_runs run_id:#{literal} limit:1"}
    end
  end

  # Only a fixed set of relative windows is accepted; the token is never built
  # from caller text.
  defp time_token(value) when value in ["last_1h", "last_24h", "last_7d", "last_30d"] do
    "time:#{value}"
  end

  defp time_token(_), do: "time:last_24h"

  defp summarise_run(run) do
    Map.put(
      run,
      "cap_explanation",
      cap_explanation(run["merge_cap_reached"], run["merges"], run["max_merges_configured"])
    )
  end

  defp cap_explanation(true, merges, cap) do
    "stopped at its configured cap of #{cap} merges after #{merges}; " <>
      "more mergeable duplicates may remain for the next run"
  end

  defp cap_explanation(_, _merges, _cap), do: "completed its work without reaching the merge cap"

  defp blocked_evidence(scope, runs, opts) do
    if opts[:include_evidence] do
      limit = SrqlBind.clamp(opts[:limit], @default_rows, @max_rows)

      runs
      |> Enum.flat_map(fn run -> List.wrap(run["blocked_component_devices"]) end)
      |> Enum.flat_map(fn component -> List.wrap(component["device_ids"]) end)
      |> Enum.uniq()
      # One seeded walk per component member would be a lot of walks; the first
      # few are enough to explain why a component is ambiguous.
      |> Enum.take(10)
      |> Enum.reduce_while({:ok, []}, fn uid, {:ok, acc} ->
        case SrqlBind.literal(uid, :device_uid) do
          {:ok, literal} ->
            case rows(scope, "in:identity_evidence_edges device:#{literal} limit:#{limit}") do
              {:ok, edges} -> {:cont, {:ok, acc ++ edges}}
              error -> {:halt, error}
            end

          {:error, _} ->
            {:cont, {:ok, acc}}
        end
      end)
      |> case do
        {:ok, edges} -> {:ok, Enum.uniq(edges)}
        error -> error
      end
    else
      {:ok, nil}
    end
  end

  # -- trace annotations -----------------------------------------------------

  # State the answers the operator came for, rather than making them re-derive
  # them from four result sets.
  defp annotate_trace(payload) do
    identifiers = payload["identifiers"]
    evidence = payload["evidence"]
    device = payload["device"]

    Map.put(payload, "summary", %{
      "tombstoned" => not is_nil(device) and not is_nil(device["deleted_at"]),
      "deleted_reason" => device && device["deleted_reason"],
      "deleted_by" => device && device["deleted_by"],
      "survivor" => survivor(payload["merge_chain"]),
      "revival_count" => length(payload["revivals"]),
      "identifier_count" => length(identifiers),
      "corroborated_identifier_count" => Enum.count(identifiers, &(&1["matches_current_facts"] == true)),
      "historical_identifier_count" => Enum.count(identifiers, &(&1["matches_current_facts"] == false)),
      "direct_evidence_edges" => Enum.count(evidence, &(&1["direct"] == true)),
      "transitive_evidence_edges" => Enum.count(evidence, &(&1["direct"] == false)),
      "cross_partition_evidence" => Enum.any?(evidence, &(&1["cross_partition"] == true)),
      "chain_truncated" => Enum.any?(payload["merge_chain"], &(&1["truncated"] == true))
    })
  end

  # The deepest `merged_into` hop is where this device's identity ended up.
  defp survivor(chain) do
    chain
    |> Enum.filter(&(&1["direction"] == "merged_into"))
    |> Enum.max_by(&(&1["depth"] || 0), fn -> nil end)
    |> case do
      nil -> nil
      edge -> edge["to_device_id"]
    end
  end

  # -- plumbing --------------------------------------------------------------

  # Errors propagate. Swallowing them into an empty result set would make a
  # `devices.view` denial read as "this device has no merge history", which is
  # the single most misleading answer this tool could give.
  defp rows(scope, query) do
    case Access.execute_query(scope, %{"query" => query}) do
      {:ok, %{"results" => results}} when is_list(results) -> {:ok, results}
      {:ok, _response} -> {:ok, []}
      {:error, reason} -> {:error, format(reason)}
    end
  end

  defp format(:forbidden), do: "forbidden: this tool requires the devices.view permission"
  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: inspect(reason)
end
