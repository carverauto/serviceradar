defmodule ServiceRadarWebNG.SRQL.CameraObservationsQueryUnitTest do
  use ExUnit.Case, async: true

  alias Ecto.Query.ByExpr
  alias ServiceRadar.Identity.User
  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL.CameraObservationsQuery

  @moduletag :db_free

  @cam_a "00000000-0000-4000-8000-000000000611"
  @cam_b "00000000-0000-4000-8000-000000000612"

  defp authorized_scope do
    %Scope{
      user: %User{id: Ecto.UUID.generate(), role: :viewer},
      permissions: MapSet.new(["devices.view", "devices.cameras.recordings.view"])
    }
  end

  defp compile_plan!(srql) do
    assert {:ok, json} = Native.translate(srql, nil, nil, nil, "legacy")
    %{"read_model" => plan} = Jason.decode!(json)
    plan
  end

  defp compile_ecto!(srql, plan_overrides \\ %{}) do
    plan = srql |> compile_plan!() |> Map.merge(plan_overrides)
    sources = %{@cam_a => "Alpha Gate 01", @cam_b => "Zulu Gate 02"}

    assert {:ok, ash_query} =
             CameraObservationsQuery.build_query(plan, authorized_scope(), [@cam_a, @cam_b], sources)

    assert ash_query.errors == []
    assert {:ok, ecto_q} = Ash.Query.data_layer_query(ash_query)
    ecto_q
  end

  test "sort:camera_display_name pushes SQL ORDER BY alongside LIMIT and OFFSET" do
    ecto_asc = compile_ecto!("in:camera_observations sort:camera_display_name:asc limit:2", %{"offset" => 1})
    assert ecto_asc.limit
    assert ecto_asc.offset
    assert [%ByExpr{expr: asc_exprs}] = ecto_asc.order_bys
    assert length(asc_exprs) == 2
    assert [{:asc_nulls_last, _}, {:desc, _}] = asc_exprs
    assert inspect(asc_exprs, limit: :infinity) =~ ":display_name"

    ecto_desc = compile_ecto!("in:camera_observations sort:camera_display_name:desc limit:1")
    assert ecto_desc.limit
    assert [%ByExpr{expr: desc_exprs}] = ecto_desc.order_bys
    assert [{:desc_nulls_last, _}, {:desc, _}] = desc_exprs
    assert inspect(desc_exprs, limit: :infinity) =~ ":display_name"
  end

  test "not_like wraps search and nullable text attributes in COALESCE(..., '') to avoid SQL NULL 3VL drops" do
    ecto_search =
      compile_ecto!("in:camera_observations limit:5", %{
        "filters" => [%{"field" => "search", "op" => "not_like", "value" => "%MISSING%"}]
      })

    search_wheres = inspect(ecto_search.wheres, limit: :infinity, printable_limit: :infinity)
    assert search_wheres =~ "COALESCE(label, '') ILIKE "
    assert search_wheres =~ "COALESCE(search_text, '') ILIKE "

    ecto_attr =
      compile_ecto!("in:camera_observations limit:5", %{
        "filters" => [
          %{"field" => "worker_id", "op" => "not_like", "value" => "%worker%"},
          %{"field" => "source_mode", "op" => "not_like", "value" => "%live%"}
        ]
      })

    attr_wheres = inspect(ecto_attr.wheres, limit: :infinity, printable_limit: :infinity)
    assert attr_wheres =~ "COALESCE("
    assert attr_wheres =~ ", '') ILIKE "
    assert attr_wheres =~ "::text, '') ILIKE "
  end

  test "base liveness filter restricts :live_keyframe_tap to nil catalog_entry_id or playable non-quarantined entries" do
    ecto_q = compile_ecto!("in:camera_observations limit:5")
    wheres_text = inspect(ecto_q.wheres, limit: :infinity, printable_limit: :infinity)

    assert wheres_text =~ ":live_keyframe_tap"
    assert wheres_text =~ ":catalog_entry_id"
    assert wheres_text =~ "is_nil"
    assert wheres_text =~ ":quarantined"
  end
end
