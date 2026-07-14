# serde-xml-rs

[![Build Status](https://travis-ci.org/RReverser/serde-xml-rs.svg?branch=master)](https://travis-ci.org/RReverser/serde-xml-rs)

`xml-rs` based deserializer for Serde (compatible with 1.0)

## Example usage

```rust
use serde;
use serde_derive::{Deserialize, Serialize};
use serde_xml_rs::{from_str, to_string};

#[derive(Debug, Serialize, Deserialize, PartialEq)]
struct Item {
    name: String,
    source: String,
}

fn main() {
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
```
