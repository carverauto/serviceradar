defmodule ServiceRadar.Observability.GeoIPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.GeoIP

  @moduletag :db_free
  @loaded_key {GeoIP, :geolix_loaded}

  setup do
    previous = Application.get_env(:geolix, :databases)

    on_exit(fn ->
      restore_database_config(previous)
      :persistent_term.erase(@loaded_key)
    end)

    :persistent_term.erase(@loaded_key)
    :ok
  end

  test "a missing configured database degrades quietly" do
    id = :serviceradar_geoip_missing_test

    source =
      Path.join(System.tmp_dir!(), "missing-geoip-#{System.unique_integer([:positive])}.mmdb")

    configure_database(id, source)
    on_exit(fn -> Geolix.unload_database(id) end)

    log = capture_log([metadata: [:id, :source]], fn -> assert :ok = GeoIP.ensure_loaded() end)

    refute log =~ "failed to load configured database"
  end

  test "an invalid existing database keeps an actionable warning" do
    id = :serviceradar_geoip_invalid_test

    source =
      Path.join(System.tmp_dir!(), "invalid-geoip-#{System.unique_integer([:positive])}.mmdb")

    File.write!(source, "not an mmdb")

    on_exit(fn -> File.rm(source) end)
    configure_database(id, source)
    on_exit(fn -> Geolix.unload_database(id) end)

    log = capture_log([metadata: [:id, :source]], fn -> assert :ok = GeoIP.ensure_loaded() end)

    assert log =~ "GeoIP: failed to load configured database"
    assert log =~ Atom.to_string(id)
    assert log =~ source
  end

  defp configure_database(id, source) do
    Application.put_env(:geolix, :databases, [
      %{id: id, adapter: Geolix.Adapter.MMDB2, source: source}
    ])
  end

  defp restore_database_config(nil), do: Application.delete_env(:geolix, :databases)
  defp restore_database_config(value), do: Application.put_env(:geolix, :databases, value)
end
