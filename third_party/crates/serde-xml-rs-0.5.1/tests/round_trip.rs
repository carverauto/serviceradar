use serde::Deserialize;
use serde_derive::{Deserialize, Serialize};
use serde_xml_rs::{self, from_str, to_string, EventReader, ParserConfig};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
struct Item {
    name: String,
    source: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
enum Node {
    Boolean(bool),
    Identifier { value: String, index: u32 },
    EOF,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
struct Nodes {
    #[serde(rename = "$value")]
    items: Vec<Node>,
}

#[test]
fn basic_struct() {
    let src = r#"<Item><name>Banana</name><source>Store</source></Item>"#;
    let should_be = Item {
        name: "Banana".to_string(),
        source: "Store".to_string(),
    };

    let item: Item = from_str(src).unwrap();
    assert_eq!(item, should_be);

    let reserialized_item = to_string(&item).unwrap();
    assert_eq!(src, reserialized_item);
}

#[test]
#[ignore]
fn round_trip_list_of_enums() {
    // Construct some inputs
    let nodes = Nodes {
        items: vec![
            Node::Boolean(true),
            Node::Identifier {
                value: "foo".to_string(),
                index: 5,
            },
            Node::EOF,
        ],
    };

    let should_be = r#"
    <Nodes>
        <Boolean>
            true
        </Boolean>
        <Identifier>
            <value>foo</value>
            <index>5</index>
        </Identifier>
        <EOF />
    </Nodes>"#;

    let serialized_nodes = to_string(&nodes).unwrap();
    assert_eq!(serialized_nodes, should_be);

    // Then turn it back into a `Nodes` struct and make sure it's the same
    // as the original
    let deserialized_nodes: Nodes = from_str(serialized_nodes.as_str()).unwrap();
    assert_eq!(deserialized_nodes, nodes);
}

#[test]
fn whitespace_preserving_config() {
    // Test a configuration which does not clip whitespace from tags

    let src = r#"
    <Item>
        <name>  space banana  </name>
        <source>   fantasy costco   </source>
    </Item>"#;

    let item_should_be = Item {
        name: "  space banana  ".to_string(),
        source: "   fantasy costco   ".to_string(),
    };
    let config = ParserConfig::new()
        .trim_whitespace(false)
        .whitespace_to_characters(false);
    let mut deserializer =
        serde_xml_rs::Deserializer::new(EventReader::new_with_config(src.as_bytes(), config));

    let item = Item::deserialize(&mut deserializer).unwrap();
    assert_eq!(item, item_should_be);

    // Space outside values is not preserved.
    let serialized_should_be =
        "<Item><name>  space banana  </name><source>   fantasy costco   </source></Item>";
    let reserialized_item = to_string(&item).unwrap();
    assert_eq!(reserialized_item, serialized_should_be);
}
