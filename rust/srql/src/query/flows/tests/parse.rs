use super::super::stats::{
    FlowAggField, FlowAggFunc, FlowGroupField, FlowGroupSpec, parse_stats_expr,
};
use super::super::*;

#[test]
fn test_parse_stats_expr() {
    let expr = "sum(bytes_total) as total_bytes by src_endpoint_ip";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.aggregations.len(), 1);
    assert_eq!(spec.aggregations[0].agg_func, FlowAggFunc::Sum);
    assert_eq!(spec.aggregations[0].agg_field, FlowAggField::BytesTotal);
    assert_eq!(spec.aggregations[0].alias, "total_bytes");
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)
    );
}

#[test]
fn test_parse_stats_expr_no_groupby() {
    let expr = "count(*) as total_flows";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.aggregations.len(), 1);
    assert_eq!(spec.aggregations[0].agg_func, FlowAggFunc::Count);
    assert_eq!(spec.aggregations[0].agg_field, FlowAggField::Star);
    assert_eq!(spec.aggregations[0].alias, "total_flows");
    assert!(spec.group_by.is_empty());
}

#[test]
fn parse_stats_expr_handles_non_ascii_before_by_delimiter() {
    let expr = "count(*) as İtotal by src_endpoint_ip";
    let spec = parse_stats_expr(expr).unwrap();

    assert_eq!(spec.aggregations.len(), 1);
    assert_eq!(spec.aggregations[0].alias, "İtotal");
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)
    );
}

#[test]
fn parse_stats_expr_rejects_non_ascii_before_as_without_panic() {
    let expr = "count(İ*) as total";
    let err = parse_stats_expr(expr).expect_err("invalid field should return a bounded error");

    assert!(matches!(err, ServiceError::InvalidRequest(_)));
}

#[test]
fn parse_stats_expr_supports_cidr_group_by() {
    let expr = "sum(bytes_total) as total_bytes by src_cidr:24";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(spec.group_by[0], FlowGroupSpec::SrcCidr { prefix: 24 });
    assert_eq!(spec.group_by[0].response_key(), "src_cidr");
}

#[test]
fn parse_stats_expr_supports_direction_group_by() {
    let expr = "count(*) as total_flows by direction";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::Direction)
    );
    assert_eq!(spec.group_by[0].response_key(), "direction");
}

#[test]
fn parse_stats_expr_supports_app_group_by() {
    let expr = "sum(bytes_total) as total_bytes by app";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(spec.group_by[0], FlowGroupSpec::Field(FlowGroupField::App));
    assert_eq!(spec.group_by[0].response_key(), "app");
}

#[test]
fn parse_stats_expr_supports_exporter_and_interface_group_by() {
    let expr = "count(*) as total_flows by exporter_name, input_snmp, output_snmp, in_if_name, out_if_name";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 5);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::ExporterName)
    );
    assert_eq!(
        spec.group_by[1],
        FlowGroupSpec::Field(FlowGroupField::InputSnmp)
    );
    assert_eq!(
        spec.group_by[2],
        FlowGroupSpec::Field(FlowGroupField::OutputSnmp)
    );
    assert_eq!(
        spec.group_by[3],
        FlowGroupSpec::Field(FlowGroupField::InIfName)
    );
    assert_eq!(
        spec.group_by[4],
        FlowGroupSpec::Field(FlowGroupField::OutIfName)
    );
}

#[test]
fn parse_stats_expr_supports_count_distinct() {
    let expr = "count_distinct(dst_endpoint_port) as unique_ports by src_endpoint_ip";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.aggregations.len(), 1);
    assert_eq!(spec.aggregations[0].agg_func, FlowAggFunc::CountDistinct);
    assert_eq!(
        spec.aggregations[0].agg_field,
        FlowAggField::DstEndpointPort
    );
    assert_eq!(spec.aggregations[0].alias, "unique_ports");
    assert_eq!(spec.group_by.len(), 1);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::SrcEndpointIp)
    );
}

#[test]
fn parse_stats_expr_supports_count_distinct_src_ip() {
    let expr = "count_distinct(src_endpoint_ip) as unique_talkers";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.aggregations.len(), 1);
    assert_eq!(spec.aggregations[0].agg_func, FlowAggFunc::CountDistinct);
    assert_eq!(spec.aggregations[0].agg_field, FlowAggField::SrcEndpointIp);
    assert_eq!(spec.aggregations[0].alias, "unique_talkers");
    assert!(spec.group_by.is_empty());
}

#[test]
fn parse_stats_expr_supports_multi_group_by() {
    let expr = "sum(bytes_total) as total_bytes by src_cidr:24, dst_endpoint_port, dst_cidr:24";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 3);
    assert_eq!(spec.group_by[0], FlowGroupSpec::SrcCidr { prefix: 24 });
    assert_eq!(
        spec.group_by[1],
        FlowGroupSpec::Field(FlowGroupField::DstEndpointPort)
    );
    assert_eq!(spec.group_by[2], FlowGroupSpec::DstCidr { prefix: 24 });
}

#[test]
fn parse_stats_expr_supports_canonical_conversation_group_by() {
    let expr = "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by conversation_a_ip, conversation_b_ip";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.group_by.len(), 2);
    assert_eq!(
        spec.group_by[0],
        FlowGroupSpec::Field(FlowGroupField::ConversationAIp)
    );
    assert_eq!(
        spec.group_by[1],
        FlowGroupSpec::Field(FlowGroupField::ConversationBIp)
    );
    assert_eq!(spec.group_by[0].response_key(), "conversation_a_ip");
    assert_eq!(spec.group_by[1].response_key(), "conversation_b_ip");
}

#[test]
fn parse_stats_expr_supports_multiple_aggregations() {
    let expr =
        "sum(bytes_total) as bytes_total, sum(packets_total) as packets_total by src_endpoint_ip";
    let spec = parse_stats_expr(expr).unwrap();
    assert_eq!(spec.aggregations.len(), 2);
    assert_eq!(spec.aggregations[0].alias, "bytes_total");
    assert_eq!(spec.aggregations[1].alias, "packets_total");
    assert_eq!(spec.group_by.len(), 1);
}
