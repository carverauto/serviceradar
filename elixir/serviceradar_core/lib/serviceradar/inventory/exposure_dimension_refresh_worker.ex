defmodule ServiceRadar.Inventory.ExposureDimensionRefreshWorker do
  @moduledoc """
  Refreshes registered CVE scores from the existing priority overlay, without
  rewriting assessments. A session lock serializes whole passes; each bounded
  page commits independently, so a retry resumes by comparing stored content.
  Source-read failures propagate before any publication, never as null scores.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Inventory.AdvisoryFeeds.CvePriority
  alias ServiceRadar.Repo

  @lock_key 7_345_220_001
  @batch_size 500

  @impl Oban.Worker
  def perform(_job) do
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock($1)", [@lock_key]).rows do
          [[true]] ->
            try do
              refresh()
            after
              Repo.query!("SELECT pg_advisory_unlock($1)", [@lock_key])
            end

          [[false]] ->
            {:snooze, 60}
        end
      end,
      timeout: 300_000
    )
  end

  defp refresh do
    priorities = CvePriority.load_map()

    if Enum.all?(priorities, fn {_, priority} -> valid_score?(priority.epss_score) end) do
      %{rows: [[last]]} =
        Repo.query!("""
        SELECT COALESCE(max(ordinal), 0) FROM platform.exposure_dimension_state WHERE kind = 'cve'
        """)

      refresh_page(priorities, 0, last)
    else
      {:error, :invalid_epss_score}
    end
  end

  defp valid_score?(nil), do: true
  defp valid_score?(score), do: is_number(score) and score >= 0 and score <= 1

  defp refresh_page(priorities, after_ordinal, last) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT ordinal, content->>'cve_id' FROM platform.exposure_dimension_state
        WHERE kind = 'cve' AND ordinal > $1 AND ordinal <= $2
        ORDER BY ordinal LIMIT $3
        """,
        [after_ordinal, last, @batch_size]
      )

    case rows do
      [] ->
        :ok

      _ ->
        scores =
          Enum.map(rows, fn [ordinal, cve_id] ->
            score =
              case Map.get(priorities, cve_id) do
                nil -> nil
                priority -> priority.epss_score
              end

            %{ordinal: ordinal, score: score}
          end)

        Repo.query!(
          """
          SELECT platform.exposure_publish_dimension('cve', d.ordinal,
            d.content || jsonb_build_object('epss_score', s.score))
          FROM platform.exposure_dimension_state d
          JOIN jsonb_to_recordset($1::jsonb) AS s(ordinal bigint, score double precision)
            ON d.ordinal = s.ordinal
          WHERE d.kind = 'cve' AND d.content->'epss_score' IS DISTINCT FROM COALESCE(to_jsonb(s.score), 'null'::jsonb)
          ORDER BY d.ordinal
          """,
          [scores]
        )

        [next, _] = List.last(rows)
        refresh_page(priorities, next, last)
    end
  end
end
