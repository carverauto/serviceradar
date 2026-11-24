use crate::{
    config::AppConfig,
    error::ServiceError,
    parser::parse,
    query::{QueryDirection, QueryRequest, translate_request},
};

fn translate_with_mode(
    query: &str,
    mode: Option<&str>,
) -> crate::error::Result<crate::query::TranslateResponse> {
    let config = AppConfig::embedded("postgres://localhost/serviceradar".to_string());
    let request = QueryRequest {
        query: query.to_string(),
        limit: None,
        cursor: None,
        direction: QueryDirection::Next,
        mode: mode.map(ToString::to_string),
        permitted_signals: None,
    };
    translate_request(&config, request)
}

fn translate_starrocks(query: &str) -> crate::error::Result<crate::query::TranslateResponse> {
    translate_with_mode(query, Some("starrocks"))
}

#[test]
fn translates_horizon_outages_with_filters_and_time_bounds() {
    let resp = translate_starrocks(
        "in:horizon_outages status:active severity:major entity_type:asn entity_key:AS13335 region:us-east covering_prefix:1.1.1.0/24 origin_asn:13335 outage_id:out-1 time:last_24h limit:25",
    )
    .expect("should translate horizon_outages");

    assert!(resp.sql.contains("FROM serviceradar.horizon_outages"));
    assert!(resp.sql.contains("`status` = 'active'"));
    assert!(resp.sql.contains("`covering_prefix` = '1.1.1.0/24'"));
    assert!(resp.sql.contains("`origin_asn` = 13335"));
    assert!(resp.sql.contains("`time` >="));
    assert!(resp.sql.contains("LIMIT 25 OFFSET 0"));
    assert!(resp.viz.is_some());
}

#[test]
fn translates_horizon_bgp_zombies_and_paths() {
    let bgp = translate_starrocks(
        "in:horizon_bgp kind:(hijack,watchlist) level:critical prefix:198.51.100.0/24 origin_asn:64512 rpki_status:invalid watchlist_id:wl-1 client_label:core-edge",
    )
    .expect("should translate horizon_bgp");
    assert!(bgp.sql.contains("FROM serviceradar.horizon_bgp_events"));
    assert!(bgp.sql.contains("`kind` IN ('hijack', 'watchlist')"));
    assert!(bgp.sql.contains("`origin_asn` = 64512"));

    let zombies = translate_starrocks(
        "in:horizon_zombies status:active prefix:203.0.113.0/24 origin_asn:64513 episode_id:ep-42 is_beacon:true divergence_pct:>=25.5",
    )
    .expect("should translate horizon_zombies");
    assert!(
        zombies
            .sql
            .contains("FROM serviceradar.horizon_bgp_zombies")
    );
    assert!(zombies.sql.contains("`is_beacon` = TRUE"));
    assert!(zombies.sql.contains("`divergence_pct` >= 25.5"));

    let paths = translate_starrocks(
        "in:horizon_paths target_id:tgt-1 pop_id:iad-1 hop_ip:198.51.100.1 router_alias_id:rtr-9 asn:15169 is_cloud:true cloud_provider:gcp mtu_blackhole_detected:false sort:hop_ttl:asc",
    )
    .expect("should translate horizon_paths");
    assert!(paths.sql.contains("FROM serviceradar.horizon_path_hops"));
    assert!(paths.sql.contains("`is_cloud` = TRUE"));
    assert!(paths.sql.contains("`mtu_blackhole_detected` = FALSE"));
    assert!(paths.sql.contains("`hop_ttl` ASC"));
}

#[test]
fn translates_horizon_isp_accountability_with_bucket_hour_filters_and_sorts() {
    let resp = translate_starrocks(
        "in:horizon_isp_accountability asn:13335 as_org:Cloudflare target_id:tgt-1 mtu_blackhole_count:>0 time:last_24h sort:forwarding_loss_pct:desc limit:20",
    )
    .expect("should translate horizon_isp_accountability");

    assert!(
        resp.sql
            .contains("FROM serviceradar.horizon_isp_accountability_mv")
    );
    for col in [
        "`day`",
        "`bucket_hour`",
        "`asn`",
        "`as_org`",
        "`target_id`",
        "`forwarding_loss_pct`",
        "`avg_rtt_ms`",
        "`max_rtt_ms`",
        "`mtu_blackhole_count`",
        "`min_effective_mtu`",
        "`active_outage_count`",
        "`bgp_anomaly_count`",
        "`bgp_zombie_count`",
        "`first_blame_tier`",
        "`sample_count`",
    ] {
        assert!(resp.sql.contains(col), "missing column {col} in {}", resp.sql);
    }
    assert!(resp.sql.contains("`asn` = 13335"));
    assert!(resp.sql.contains("`as_org` = 'Cloudflare'"));
    assert!(resp.sql.contains("`target_id` = 'tgt-1'"));
    assert!(resp.sql.contains("`mtu_blackhole_count` > 0"));
    assert!(resp.sql.contains("`bucket_hour` >="));
    assert!(resp.sql.contains("`bucket_hour` <="));
    assert!(!resp.sql.contains("`time` >="));
    assert!(!resp.sql.contains("`time` <="));
    assert!(resp.sql.contains("ORDER BY `forwarding_loss_pct` DESC"));
    assert!(resp.sql.contains("LIMIT 20 OFFSET 0"));
    assert_eq!(resp.params.len(), 2);

    let viz = resp.viz.expect("should include viz metadata");
    let col_names: Vec<&str> = viz.columns.iter().map(|c| c.name.as_str()).collect();
    assert!(col_names.contains(&"bucket_hour"));
    assert!(col_names.contains(&"mtu_blackhole_count"));
    assert!(col_names.contains(&"first_blame_tier"));
}

#[test]
fn horizon_isp_accountability_default_sort_time_alias_and_raw_mode_use_bucket_hour() {
    let default_resp = translate_starrocks("in:horizon_isp_accountability limit:10")
        .expect("default sort should translate");
    assert!(default_resp.sql.contains("ORDER BY `bucket_hour` DESC"));

    let time_asc = translate_starrocks("in:horizon_isp_accountability sort:time:asc limit:10")
        .expect("sort:time:asc should map to bucket_hour");
    assert!(time_asc.sql.contains("ORDER BY `bucket_hour` ASC"));

    let bucket_asc =
        translate_starrocks("in:horizon_isp_accountability sort:bucket_hour:asc limit:10")
            .expect("sort:bucket_hour:asc should translate");
    assert!(bucket_asc.sql.contains("ORDER BY `bucket_hour` ASC"));

    let raw_mode =
        translate_with_mode("in:horizon_isp_accountability sort:time:asc limit:10", Some("starrocks_raw"))
            .expect("starrocks_raw should safely compile MV query");
    assert_eq!(raw_mode.sql, time_asc.sql);
}

#[test]
fn horizon_isp_accountability_additional_filters_and_errors() {
    let resp = translate_starrocks(
        "in:horizon_isp_accountability first_blame_tier:isp_transit active_outage_count:>=1 bgp_anomaly_count:>0 bgp_zombie_count:0 min_effective_mtu:<1500 forwarding_loss_pct:>=5.5 as_org:(Cloudflare,Fastly) sort:max_rtt_ms:desc",
    )
    .expect("additional filters should translate");

    assert!(resp.sql.contains("`first_blame_tier` = 'isp_transit'"));
    assert!(resp.sql.contains("`active_outage_count` >= 1"));
    assert!(resp.sql.contains("`bgp_anomaly_count` > 0"));
    assert!(resp.sql.contains("`bgp_zombie_count` = 0"));
    assert!(resp.sql.contains("`min_effective_mtu` < 1500"));
    assert!(resp.sql.contains("`forwarding_loss_pct` >= 5.5"));
    assert!(resp.sql.contains("`as_org` IN ('Cloudflare', 'Fastly')"));
    assert!(resp.sql.contains("ORDER BY `max_rtt_ms` DESC"));

    for bad in [
        "in:horizon_isp_accountability hop_ttl:1",
        "in:horizon_isp_accountability stats:count() as n",
        "in:horizon_isp_accountability bucket:1h",
        "in:horizon_isp_accountability other:true",
    ] {
        assert!(
            matches!(translate_starrocks(bad), Err(ServiceError::InvalidRequest(_))),
            "expected InvalidRequest for '{bad}'"
        );
    }
}

#[test]
fn rejects_non_starrocks_mode_and_removed_aliases() {
    for entity in [
        "horizon_outages",
        "horizon_bgp",
        "horizon_zombies",
        "horizon_paths",
        "horizon_isp_accountability",
    ] {
        assert!(matches!(
            translate_with_mode(&format!("in:{entity} limit:10"), None),
            Err(ServiceError::InvalidRequest(_))
        ));
    }

    for removed_alias in [
        "horizon_outage",
        "horizon_bgp_events",
        "horizon_bgp_event",
        "horizon_bgp_zombies",
        "horizon_bgp_zombie",
        "horizon_path_hops",
        "horizon_path_hop",
        "horizon_isp_accountability_mv",
    ] {
        assert!(
            parse(&format!("in:{removed_alias}")).is_err(),
            "expected removed alias '{removed_alias}' to be rejected"
        );
    }
}

#[test]
fn rejects_unknown_filters_and_unsupported_clauses() {
    assert!(matches!(
        translate_starrocks("in:horizon_outages prefix:1.1.1.0/24"),
        Err(ServiceError::InvalidRequest(_))
    ));
    assert!(matches!(
        translate_starrocks("in:horizon_bgp unknown:val"),
        Err(ServiceError::InvalidRequest(_))
    ));
    assert!(matches!(
        translate_starrocks("in:horizon_zombies stats:count() as n"),
        Err(ServiceError::InvalidRequest(_))
    ));
    assert!(matches!(
        translate_starrocks("in:horizon_paths bucket:5m"),
        Err(ServiceError::InvalidRequest(_))
    ));
}
