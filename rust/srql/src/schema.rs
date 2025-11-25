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

    pollers (poller_id) {
        poller_id -> Text,
        component_id -> Nullable<Text>,
        registration_source -> Nullable<Text>,
        status -> Nullable<Text>,
        spiffe_identity -> Nullable<Text>,
        first_registered -> Nullable<Timestamptz>,
        first_seen -> Nullable<Timestamptz>,
        last_seen -> Nullable<Timestamptz>,
        metadata -> Nullable<Jsonb>,
        created_by -> Nullable<Text>,
        is_healthy -> Nullable<Bool>,
        agent_count -> Nullable<Int4>,
        checker_count -> Nullable<Int4>,
        updated_at -> Nullable<Timestamptz>,
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
    use diesel::pg::sql_types::Array;
    use diesel::sql_types::*;

    discovered_interfaces (timestamp, device_id, if_index) {
        timestamp -> Timestamptz,
        agent_id -> Nullable<Text>,
        poller_id -> Nullable<Text>,
        device_ip -> Nullable<Text>,
        device_id -> Nullable<Text>,
        if_index -> Nullable<Int4>,
        if_name -> Nullable<Text>,
        if_descr -> Nullable<Text>,
        if_alias -> Nullable<Text>,
        if_speed -> Nullable<Int8>,
        if_phys_address -> Nullable<Text>,
        ip_addresses -> Nullable<Array<Text>>,
        if_admin_status -> Nullable<Int4>,
        if_oper_status -> Nullable<Int4>,
        metadata -> Nullable<Jsonb>,
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

diesel::table! {
    use diesel::sql_types::*;

    timeseries_metrics (timestamp, poller_id, metric_name) {
        timestamp -> Timestamptz,
        poller_id -> Text,
        agent_id -> Nullable<Text>,
        metric_name -> Text,
        metric_type -> Text,
        device_id -> Nullable<Text>,
        value -> Float8,
        unit -> Nullable<Text>,
        tags -> Nullable<Jsonb>,
        partition -> Nullable<Text>,
        scale -> Nullable<Float8>,
        is_delta -> Nullable<Bool>,
        target_device_ip -> Nullable<Text>,
        if_index -> Nullable<Int4>,
        metadata -> Nullable<Jsonb>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    cpu_metrics (timestamp, poller_id, core_id) {
        timestamp -> Timestamptz,
        poller_id -> Text,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        core_id -> Nullable<Int4>,
        usage_percent -> Nullable<Float8>,
        frequency_hz -> Nullable<Float8>,
        label -> Nullable<Text>,
        cluster -> Nullable<Text>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    disk_metrics (timestamp, poller_id, mount_point) {
        timestamp -> Timestamptz,
        poller_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        mount_point -> Nullable<Text>,
        device_name -> Nullable<Text>,
        total_bytes -> Nullable<Int8>,
        used_bytes -> Nullable<Int8>,
        available_bytes -> Nullable<Int8>,
        usage_percent -> Nullable<Float8>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    memory_metrics (timestamp, poller_id) {
        timestamp -> Timestamptz,
        poller_id -> Nullable<Text>,
        agent_id -> Nullable<Text>,
        host_id -> Nullable<Text>,
        total_bytes -> Nullable<Int8>,
        used_bytes -> Nullable<Int8>,
        available_bytes -> Nullable<Int8>,
        usage_percent -> Nullable<Float8>,
        device_id -> Nullable<Text>,
        partition -> Nullable<Text>,
        created_at -> Timestamptz,
    }
}

diesel::table! {
    use diesel::sql_types::*;

    device_updates (observed_at, device_id) {
        observed_at -> Timestamptz,
        agent_id -> Text,
        poller_id -> Text,
        partition -> Text,
        device_id -> Text,
        discovery_source -> Text,
        ip -> Nullable<Text>,
        mac -> Nullable<Text>,
        hostname -> Nullable<Text>,
        available -> Nullable<Bool>,
        metadata -> Nullable<Jsonb>,
        created_at -> Timestamptz,
    }
}
