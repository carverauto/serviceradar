//! Example demonstrating manual creation of IPFIX packets.
//!
//! This example shows how to create IPFIX packets from scratch. The library provides
//! the `calculate_padding` function to help calculate the correct padding bytes needed
//! to align FlowSets to 4-byte boundaries.

use netflow_parser::variable_versions::field_value::FieldValue;
use netflow_parser::variable_versions::ipfix::lookup::{IANAIPFixField, IPFixField};
use netflow_parser::variable_versions::ipfix::{
    Data, FlowSet, FlowSetBody, FlowSetHeader, Header, IPFix, Template, TemplateField,
};
use std::net::Ipv4Addr;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create a simple IPFIX header
    let header = Header {
        version: 10,
        length: 0, // Will be calculated based on actual size
        export_time: 1234567890,
        sequence_number: 1,
        observation_domain_id: 0,
    };

    // Create a template with 3 fields (which will need 1 byte of padding)
    // Template structure: template_id (2) + field_count (2) + 3 fields * 4 bytes = 16 bytes
    // 16 bytes is already aligned to 4, but let's create one that needs padding

    // Actually, let's create a template with 1 field to demonstrate padding
    // Template: template_id (2) + field_count (2) + 1 field * 4 bytes = 8 bytes (no padding needed)
    // Let's add a field with enterprise bit set: + 4 bytes enterprise = 12 bytes (no padding)

    // For demonstration, let's create a simple template that shows the concept
    let template = Template {
        template_id: 256,
        field_count: 2,
        fields: vec![
            TemplateField {
                field_type_number: 8, // sourceIPv4Address
                field_length: 4,
                enterprise_number: None,
                field_type: IPFixField::IANA(IANAIPFixField::SourceIpv4address),
            },
            TemplateField {
                field_type_number: 12, // destinationIPv4Address
                field_length: 4,
                enterprise_number: None,
                field_type: IPFixField::IANA(IANAIPFixField::DestinationIpv4address),
            },
        ],
    };

    // Calculate the template flowset length
    // Header: 4 bytes (flowset_id + length)
    // Template: 2 (template_id) + 2 (field_count) + 2 fields * 4 bytes = 12 bytes
    // Total: 16 bytes (perfectly aligned, no padding needed)
    let template_flowset = FlowSet {
        header: FlowSetHeader {
            header_id: 2, // Template FlowSet ID
            length: 16,
        },
        body: FlowSetBody::Template(template.clone()),
    };

    // Create data flowset with actual flow records
    let data = Data::new(vec![vec![
        (
            IPFixField::IANA(IANAIPFixField::SourceIpv4address),
            FieldValue::Ip4Addr(Ipv4Addr::new(192, 168, 1, 1)),
        ),
        (
            IPFixField::IANA(IANAIPFixField::DestinationIpv4address),
            FieldValue::Ip4Addr(Ipv4Addr::new(10, 0, 0, 1)),
        ),
    ]]);

    // Data content: 2 fields * 4 bytes = 8 bytes (already aligned, no padding needed in this case)
    // If we had unaligned data, we could use calculate_padding() to determine padding bytes needed
    let data_flowset = FlowSet {
        header: FlowSetHeader {
            header_id: 256, // Matches template_id
            length: 12,     // Header (4) + Data (8) = 12 bytes
        },
        body: FlowSetBody::Data(data),
    };

    // Create the IPFIX packet
    let mut ipfix = IPFix {
        header,
        flowsets: vec![template_flowset, data_flowset],
    };

    // Update the total length in the header
    ipfix.header.length = 16 + 16 + 12; // Header + Template FlowSet + Data FlowSet = 44 bytes

    // Export to bytes
    let exported_bytes = ipfix.to_be_bytes()?;

    println!("Created IPFIX packet with {} bytes", exported_bytes.len());
    println!("Header length field: {}", ipfix.header.length);
    println!(
        "Actual exported length: {} (should match header.length)",
        exported_bytes.len()
    );

    // Verify the packet structure
    println!("\nPacket structure:");
    println!("- IPFIX Header: 16 bytes");
    println!(
        "- Template FlowSet: {} bytes",
        ipfix.flowsets[0].header.length
    );
    println!("- Data FlowSet: {} bytes", ipfix.flowsets[1].header.length);

    println!("\n✓ Use calculate_padding() to calculate alignment when needed!");

    Ok(())
}
