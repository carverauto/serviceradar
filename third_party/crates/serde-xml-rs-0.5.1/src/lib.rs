//! # Serde XML
//!
//! XML is a flexible markup language that is still used for sharing data between applications or
//! for writing configuration files.
//!
//! Serde XML provides a way to convert between text and strongly-typed Rust data structures.
//!
//! ## Caveats
//!
//! The Serde framework was mainly designed with formats such as JSON or YAML in mind.
//! As opposed to XML, these formats have the advantage of a stricter syntax which makes it
//! possible to know what type a field is without relying on an accompanying schema,
//! and disallows repeating the same tag multiple times in the same object.
//!
//! For example, encoding the following document in YAML is not trivial.
//!
//! ```xml
//! <document>
//!   <header>A header</header>
//!   <section>First section</section>
//!   <section>Second section</section>
//!   <sidenote>A sidenote</sidenote>
//!   <section>Third section</section>
//!   <sidenote>Another sidenote</sidenote>
//!   <section>Fourth section</section>
//!   <footer>The footer</footer>
//! </document>
//! ```
//!
//! One possibility is the following YAML document.
//!
//! ```yaml
//! - header: A header
//! - section: First section
//! - section: Second section
//! - sidenote: A sidenote
//! - section: Third section
//! - sidenote: Another sidenote
//! - section: Fourth section
//! - footer: The footer
//! ```
//!
//! Other notable differences:
//! - XML requires a named root node.
//! - XML has a namespace system.
//! - XML distinguishes between attributes, child tags and contents.
//! - In XML, the order of nodes is sometimes important.
//!
//! ## Basic example
//!
//! ```rust
//! use serde;
//! use serde_derive::{Deserialize, Serialize};
//! use serde_xml_rs::{from_str, to_string};
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Item {
//!     name: String,
//!     source: String,
//! }
//!
//! fn main() {
//!     let src = r#"<Item><name>Banana</name><source>Store</source></Item>"#;
//!     let should_be = Item {
//!         name: "Banana".to_string(),
//!         source: "Store".to_string(),
//!     };
//!
//!     let item: Item = from_str(src).unwrap();
//!     assert_eq!(item, should_be);
//!
//!     let reserialized_item = to_string(&item).unwrap();
//!     assert_eq!(src, reserialized_item);
//! }
//! ```
//!
//! ## Tag contents
//!
//! ```rust
//! # use serde;
//! # use serde_derive::{Deserialize, Serialize};
//! # use serde_xml_rs::{from_str, to_string};
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Document {
//!     content: Content
//! }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Content {
//!     #[serde(rename = "$value")]
//!     value: String
//! }
//!
//! fn main() {
//!     let src = r#"<document><content>Lorem ipsum</content></document>"#;
//!     let document: Document = from_str(src).unwrap();
//!     assert_eq!(document.content.value, "Lorem ipsum");
//! }
//! ```
//!
//! ## Repeated tags
//!
//! ```rust
//! # use serde;
//! # use serde_derive::{Deserialize, Serialize};
//! # use serde_xml_rs::{from_str, to_string};
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct PlateAppearance {
//!     #[serde(rename = "$value")]
//!     events: Vec<Event>
//! }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! #[serde(rename_all = "kebab-case")]
//! enum Event {
//!     Pitch(Pitch),
//!     Runner(Runner),
//! }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Pitch {
//!     speed: u32,
//!     r#type: PitchType,
//!     outcome: PitchOutcome,
//! }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! enum PitchType { FourSeam, TwoSeam, Changeup, Cutter, Curve, Slider, Knuckle, Pitchout }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! enum PitchOutcome { Ball, Strike, Hit }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Runner {
//!     from: Base, to: Option<Base>, outcome: RunnerOutcome,
//! }
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! enum Base { First, Second, Third, Home }
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! enum RunnerOutcome { Steal, Caught, PickOff }
//!
//! fn main() {
//!     let document = r#"
//!         <plate-appearance>
//!           <pitch speed="95" type="FourSeam" outcome="Ball" />
//!           <pitch speed="91" type="FourSeam" outcome="Strike" />
//!           <pitch speed="85" type="Changeup" outcome="Ball" />
//!           <runner from="First" to="Second" outcome="Steal" />
//!           <pitch speed="89" type="Slider" outcome="Strike" />
//!           <pitch speed="88" type="Curve" outcome="Hit" />
//!         </plate-appearance>"#;
//!     let plate_appearance: PlateAppearance = from_str(document).unwrap();
//!     assert_eq!(plate_appearance.events[0], Event::Pitch(Pitch { speed: 95, r#type: PitchType::FourSeam, outcome: PitchOutcome::Ball }));
//! }
//! ```
//!
//! ## Custom EventReader
//!
//! ```rust
//! use serde::Deserialize;
//! use serde_derive::{Deserialize, Serialize};
//! use serde_xml_rs::{from_str, to_string, de::Deserializer};
//! use xml::reader::{EventReader, ParserConfig};
//!
//! #[derive(Debug, Serialize, Deserialize, PartialEq)]
//! struct Item {
//!     name: String,
//!     source: String,
//! }
//!
//! fn main() {
//!     let src = r#"<Item><name>  Banana  </name><source>Store</source></Item>"#;
//!     let should_be = Item {
//!         name: "  Banana  ".to_string(),
//!         source: "Store".to_string(),
//!     };
//!
//!     let config = ParserConfig::new()
//!         .trim_whitespace(false)
//!         .whitespace_to_characters(true);
//!     let event_reader = EventReader::new_with_config(src.as_bytes(), config);
//!     let item = Item::deserialize(&mut Deserializer::new(event_reader)).unwrap();
//!     assert_eq!(item, should_be);
//! }
//! ```
//!

pub mod de;
mod error;
pub mod ser;

pub use crate::de::{from_reader, from_str, Deserializer};
pub use crate::error::Error;
pub use crate::ser::{to_string, to_writer, Serializer};
pub use xml::reader::{EventReader, ParserConfig};
