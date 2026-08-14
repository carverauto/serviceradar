defmodule ServiceRadar.Observability.GeoIPTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Observability.GeoIP

  @moduletag :db_free
  @loaded_key {GeoIP, :geolix_loaded}

  setup do
    previous_geolix = Application.get_env(:geolix, :databases)
    previous_candidates = Application.get_env(:serviceradar_core, :geolite_databases)

    on_exit(fn ->
      restore_env(:geolix, :databases, previous_geolix)
      restore_env(:serviceradar_core, :geolite_databases, previous_candidates)
      :persistent_term.erase(@loaded_key)
    end)

    :persistent_term.erase(@loaded_key)
    :ok
  end

  test "present_databases drops specs whose source is not on disk" do
    missing =
      Path.join(System.tmp_dir!(), "missing-geoip-#{System.unique_integer([:positive])}.mmdb")

    present =
      Path.join(System.tmp_dir!(), "present-geoip-#{System.unique_integer([:positive])}.mmdb")

    File.write!(present, "placeholder")
    on_exit(fn -> File.rm(present) end)

    assert [%{id: :keep}] =
             GeoIP.present_databases([
               %{id: :keep, source: present},
               %{id: :drop, source: missing}
             ])
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
    databases = [%{id: id, adapter: Geolix.Adapter.MMDB2, source: source}]
    Application.put_env(:geolix, :databases, databases)
    Application.put_env(:serviceradar_core, :geolite_databases, databases)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
