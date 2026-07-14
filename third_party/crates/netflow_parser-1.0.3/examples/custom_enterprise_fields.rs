//! Example demonstrating how to register custom enterprise-specific IPFIX fields
//!
//! This example shows how library users can define their own enterprise fields
//! without modifying the library source code.

use netflow_parser::NetflowParser;
use netflow_parser::variable_versions::enterprise_registry::EnterpriseFieldDef;
use netflow_parser::variable_versions::field_value::FieldDataType;

fn main() {
    // Define custom enterprise fields for a hypothetical "Acme Corp" with enterprise number 12345
    let custom_fields = vec![
        EnterpriseFieldDef::new(
            12345, // Enterprise number
            1,     // Field number
            "acmeCustomMetric",
            FieldDataType::UnsignedDataNumber,
        ),
        EnterpriseFieldDef::new(12345, 2, "acmeApplicationName", FieldDataType::String),
        EnterpriseFieldDef::new(12345, 3, "acmeSourceIpAddress", FieldDataType::Ip4Addr),
        EnterpriseFieldDef::new(
            12345,
            4,
            "acmeTimestampMillis",
            FieldDataType::DurationMillis,
        ),
    ];

    // Create a parser with registered custom enterprise fields
    let mut _parser = NetflowParser::builder()
        .with_cache_size(1000)
        .register_enterprise_fields(custom_fields)
        .build()
        .expect("Failed to build parser");

    println!("Parser created with custom enterprise fields registered!");
    println!("Enterprise fields for enterprise number 12345:");
    println!("  - Field 1: acmeCustomMetric (UnsignedDataNumber)");
    println!("  - Field 2: acmeApplicationName (String)");
    println!("  - Field 3: acmeSourceIpAddress (IPv4 Address)");
    println!("  - Field 4: acmeTimestampMillis (Duration in milliseconds)");
    println!();
    println!("When IPFIX packets with these enterprise fields are parsed,");
    println!("they will be automatically decoded using the specified data types");
    println!("instead of being treated as raw bytes.");

    // You can also register fields individually
    let mut _parser2 = NetflowParser::builder()
        .register_enterprise_field(EnterpriseFieldDef::new(
            54321,
            1,
            "vendorSpecificField",
            FieldDataType::Ip6Addr,
        ))
        .build()
        .expect("Failed to build parser");

    println!();
    println!("Second parser created with a single enterprise field for enterprise 54321");

    // In actual usage, you would parse IPFIX packets like this:
    // let packets = parser.parse_bytes(&buffer);
    // Custom enterprise fields would be automatically parsed according to their registered types
}
