defmodule ServiceRadar.Observability.AnomalyDetection.ConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.Config, as: EventWriterConfig
  alias ServiceRadar.Observability.AnomalyDetection
  alias ServiceRadar.Observability.AnomalyDetection.Config

  setup do
    previous_enabled = Application.get_env(:serviceradar_core, :anomaly_analysis_consumer_enabled)
    previous_config = Application.get_env(:serviceradar_core, AnomalyDetection)

    on_exit(fn ->
      restore_env(:anomaly_analysis_consumer_enabled, previous_enabled)
      restore_env(AnomalyDetection, previous_config)
      System.delete_env("ANOMALY_ANALYSIS_CONSUMER_ENABLED")
      System.delete_env("ANOMALY_ANALYSIS_ENABLED_SUBJECTS")
      System.delete_env("ANOMALY_ANALYSIS_NATS_URL")
      System.delete_env("ANOMALY_ANALYSIS_NATS_CREDS_FILE")
      System.delete_env("ANOMALY_TEST_NATS_PASSWORD")
    end)

    :ok
  end

  test "is disabled by default" do
    refute Config.enabled?()
  end

  test "reads enabled flag from env" do
    System.put_env("ANOMALY_ANALYSIS_CONSUMER_ENABLED", "true")

    assert Config.enabled?()
  end

  test "default streams use live-only consumers with inactive threshold" do
    streams = Config.default_streams()

    assert Enum.map(streams, & &1.subject) == [
             "metrics.sysmon.*",
             "metrics.snmp.>",
             "otel.metrics.>",
             "flows.raw.netflow",
             "flows.raw.sflow",
             "flow.attributed.>"
           ]

    assert Enum.all?(streams, &(&1.consumer_deliver_policy == :new))
    assert Enum.all?(streams, &is_integer(&1.consumer_inactive_threshold))
    assert Enum.all?(streams, &(&1.consumer_max_deliver == 3))
  end

  test "defaults processing to otel metrics only" do
    config = Config.load()

    assert config.enabled_subjects == ["otel.metrics.>"]
    assert Config.subject_enabled?(config, "otel.metrics.raw")
    refute Config.subject_enabled?(config, "metrics.sysmon.cpu")
  end

  test "supports per-subject enable filters" do
    System.put_env("ANOMALY_ANALYSIS_ENABLED_SUBJECTS", "metrics.sysmon.*,metrics.snmp.>")

    config = Config.load()

    assert Config.subject_enabled?(config, "metrics.sysmon.cpu")
    assert Config.subject_enabled?(config, "metrics.snmp.interface.ifHCInOctets")
    refute Config.subject_enabled?(config, "otel.metrics.raw")
  end

  test "materializes an EventWriter-compatible producer config" do
    config = Config.load()
    producer_config = Config.to_event_writer_config(config)

    assert %EventWriterConfig{} = producer_config
    assert producer_config.consumer_name == "serviceradar-anomaly-analysis"
    assert producer_config.producer_name == ServiceRadar.Observability.AnomalyDetection.Producer
    assert producer_config.streams == config.streams
  end

  test "normalizes production keyword-list nats config for the EventWriter producer" do
    creds_path =
      Path.join(System.tmp_dir!(), "serviceradar-anomaly-#{System.unique_integer()}.creds")

    File.write!(creds_path, """
    -----BEGIN NATS USER JWT-----
    test-jwt
    ------END NATS USER JWT------

    -----BEGIN USER NKEY SEED-----
    test-seed
    ------END USER NKEY SEED------
    """)

    on_exit(fn -> File.rm(creds_path) end)

    System.put_env("ANOMALY_TEST_NATS_PASSWORD", "secret")

    Application.put_env(:serviceradar_core, AnomalyDetection,
      nats: [
        host: "nats.prod",
        port: 4223,
        user: "analysis",
        password: {:system, "ANOMALY_TEST_NATS_PASSWORD"},
        creds_file: creds_path,
        tls: [verify: :verify_peer]
      ]
    )

    config = Config.load()
    producer_config = Config.to_event_writer_config(config)

    assert config.nats == %{
             host: "nats.prod",
             port: 4223,
             user: "analysis",
             password: "secret",
             creds_file: creds_path,
             jwt: "test-jwt",
             nkey_seed: "test-seed",
             tls: [verify: :verify_peer]
           }

    assert producer_config.nats == config.nats
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
