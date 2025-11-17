//! Diesel schema definitions for CNPG tables used by SRQL.

diesel::table! {
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    unified_devices (device_id) {
        device_id -> Text,
        ip -> Nullable<Text>,
        poller_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        hostname -> Nullable<Text>,
        mac -> Nullable<Text>,
        discovery_sources -> Nullable<Array<Text>>,
        is_available -> Bool,
        first_seen -> Timestamptz,
        last_seen -> Timestamptz,
        metadata -> Nullable<Jsonb>,
        device_type -> Nullable<Text>,
        service_type -> Nullable<Text>,
        service_status -> Nullable<Text>,
        last_heartbeat -> Nullable<Timestamptz>,
        os_info -> Nullable<Text>,
        version_info -> Nullable<Text>,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    events (event_timestamp, id) {
        event_timestamp -> Timestamptz,
        specversion -> Nullable<Text>,
        id -> Text,
        source -> Nullable<Text>,
        #[sql_name = "type"]
        event_type -> Nullable<Text>,
        datacontenttype -> Nullable<Text>,
        subject -> Nullable<Text>,
        remote_addr -> Nullable<Text>,
        host -> Nullable<Text>,
        level -> Nullable<Int4>,
        severity -> Nullable<Text>,
        short_message -> Nullable<Text>,
        version -> Nullable<Text>,
        raw_data -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    logs (timestamp, trace_id, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        severity_text -> Nullable<Text>,
        severity_number -> Nullable<Int4>,
        body -> Nullable<Text>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    service_status (timestamp, poller_id, service_name) {
        timestamp -> Timestamptz,
        poller_id -> Text,
        agent_id -> Nullable<Text>,
        service_name -> Text,
        service_type -> Nullable<Text>,
        available -> Bool,
        message -> Nullable<Text>,
        details -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    otel_traces (timestamp, trace_id, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Text,
        parent_span_id -> Nullable<Text>,
        name -> Nullable<Text>,
        kind -> Nullable<Int4>,
        start_time_unix_nano -> Nullable<Int8>,
        end_time_unix_nano -> Nullable<Int8>,
        service_name -> Nullable<Text>,
        service_version -> Nullable<Text>,
        service_instance -> Nullable<Text>,
        scope_name -> Nullable<Text>,
        scope_version -> Nullable<Text>,
        status_code -> Nullable<Int4>,
        status_message -> Nullable<Text>,
        attributes -> Nullable<Text>,
        resource_attributes -> Nullable<Text>,
        events -> Nullable<Text>,
        links -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    otel_metrics (timestamp, span_name, service_name, span_id) {
        timestamp -> Timestamptz,
        trace_id -> Nullable<Text>,
        span_id -> Nullable<Text>,
        service_name -> Nullable<Text>,
        span_name -> Nullable<Text>,
        span_kind -> Nullable<Text>,
        duration_ms -> Nullable<Float8>,
        duration_seconds -> Nullable<Float8>,
        metric_type -> Nullable<Text>,
        http_method -> Nullable<Text>,
        http_route -> Nullable<Text>,
        http_status_code -> Nullable<Text>,
        grpc_service -> Nullable<Text>,
        grpc_method -> Nullable<Text>,
        grpc_status_code -> Nullable<Text>,
        is_slow -> Nullable<Bool>,
        component -> Nullable<Text>,
        level -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}
