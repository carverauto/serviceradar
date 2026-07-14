use serde::Deserialize;
use serde_derive::Deserialize;
use serde_xml_rs::{from_str, Deserializer};
use simple_logger::SimpleLogger;

fn init_logger() {
    let _ = SimpleLogger::new().init();
}

#[derive(Debug, Deserialize, PartialEq)]
struct Item {
    name: String,
    source: String,
}

#[test]
fn simple_struct_from_attributes() {
    init_logger();

    let s = r##"
        <item name="hello" source="world.rs" />
    "##;

    let item: Item = from_str(s).unwrap();

    assert_eq!(
        item,
        Item {
            name: "hello".to_string(),
            source: "world.rs".to_string(),
        }
    );
}

#[test]
fn multiple_roots_attributes() {
    init_logger();

    let s = r##"
        <item name="hello" source="world.rs" />
        <item name="hello" source="world.rs" />
    "##;

    let item: Vec<Item> = from_str(s).unwrap();

    assert_eq!(
        item,
        vec![
            Item {
                name: "hello".to_string(),
                source: "world.rs".to_string(),
            },
            Item {
                name: "hello".to_string(),
                source: "world.rs".to_string(),
            },
        ]
    );
}

#[test]
fn simple_struct_from_attribute_and_child() {
    init_logger();

    let s = r##"
        <item name="hello">
            <source>world.rs</source>
        </item>
    "##;

    let item: Item = from_str(s).unwrap();

    assert_eq!(
        item,
        Item {
            name: "hello".to_string(),
            source: "world.rs".to_string(),
        }
    );
}

#[derive(Debug, Deserialize, PartialEq)]
struct Project {
    name: String,

    #[serde(rename = "item", default)]
    items: Vec<Item>,
}

#[test]
fn nested_collection() {
    init_logger();

    let s = r##"
        <project name="my_project">
            <item name="hello1" source="world1.rs" />
            <item name="hello2" source="world2.rs" />
        </project>
    "##;

    let project: Project = from_str(s).unwrap();

    assert_eq!(
        project,
        Project {
            name: "my_project".to_string(),
            items: vec![
                Item {
                    name: "hello1".to_string(),
                    source: "world1.rs".to_string(),
                },
                Item {
                    name: "hello2".to_string(),
                    source: "world2.rs".to_string(),
                },
            ],
        }
    );
}

#[derive(Debug, Deserialize, PartialEq)]
enum MyEnum {
    A(String),
    B { name: String, flag: bool },
    C,
}

#[derive(Debug, Deserialize, PartialEq)]
struct MyEnums {
    #[serde(rename = "$value")]
    items: Vec<MyEnum>,
}

#[test]
fn collection_of_enums() {
    init_logger();

    let s = r##"
        <enums>
            <A>test</A>
            <B name="hello" flag="true" />
            <C />
        </enums>
    "##;

    let project: MyEnums = from_str(s).unwrap();

    assert_eq!(
        project,
        MyEnums {
            items: vec![
                MyEnum::A("test".to_string()),
                MyEnum::B {
                    name: "hello".to_string(),
                    flag: true,
                },
                MyEnum::C,
            ],
        }
    );
}

#[test]
fn out_of_order_collection() {
    #[derive(Debug, Deserialize, PartialEq)]
    struct Collection {
        a: Vec<A>,
        b: Vec<B>,
        c: C,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct A {
        name: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct B {
        name: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct C {
        name: String,
    }

    init_logger();

    let in_xml = r#"
        <collection>
            <a name="a1" />
            <a name="a2" />
            <b name="b1" />
            <a name="a3" />
            <c name="c" />
            <b name="b2" />
            <a name="a4" />
        </collection>
    "#;

    let should_be = Collection {
        a: vec![
            A { name: "a1".into() },
            A { name: "a2".into() },
            A { name: "a3".into() },
            A { name: "a4".into() },
        ],
        b: vec![B { name: "b1".into() }, B { name: "b2".into() }],
        c: C { name: "c".into() },
    };

    let mut de = Deserializer::new_from_reader(in_xml.as_bytes()).non_contiguous_seq_elements(true);
    let actual = Collection::deserialize(&mut de).unwrap();

    assert_eq!(should_be, actual);
}

#[test]
fn nested_out_of_order_collection() {
    #[derive(Debug, Deserialize, PartialEq)]
    struct OuterCollection {
        a: A,
        inner: Vec<InnerCollection>,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct InnerCollection {
        b: Vec<B>,
        c: Vec<C>,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct A {
        name: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct B {
        name: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct C {
        name: String,
    }

    init_logger();

    let in_xml = r#"
        <collection>
            <inner>
                <b name="b1" />
                <c name="c1" />
                <b name="b2" />
                <c name="c2" />
            </inner>
            <a name="a" />
            <inner>
                <c name="c3" />
                <b name="b3" />
                <c name="c4" />
                <b name="b4" />
            </inner>
        </collection>
    "#;

    let should_be = OuterCollection {
        a: A { name: "a".into() },
        inner: vec![
            InnerCollection {
                b: vec![B { name: "b1".into() }, B { name: "b2".into() }],
                c: vec![C { name: "c1".into() }, C { name: "c2".into() }],
            },
            InnerCollection {
                b: vec![B { name: "b3".into() }, B { name: "b4".into() }],
                c: vec![C { name: "c3".into() }, C { name: "c4".into() }],
            },
        ],
    };

    let mut de = Deserializer::new_from_reader(in_xml.as_bytes()).non_contiguous_seq_elements(true);
    let actual = OuterCollection::deserialize(&mut de).unwrap();

    assert_eq!(should_be, actual);
}

#[test]
fn out_of_order_tuple() {
    #[derive(Debug, Deserialize, PartialEq)]
    struct Collection {
        val: (A, B, C),
        other: A,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct A {
        name_a: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct B {
        name_b: String,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct C {
        name_c: String,
    }

    init_logger();

    let in_xml = r#"
        <collection>
            <val name_a="a1" />
            <val name_b="b" />
            <other name_a="a2" />
            <val name_c="c" />
        </collection>
    "#;

    let should_be = Collection {
        val: (
            A {
                name_a: "a1".into(),
            },
            B { name_b: "b".into() },
            C { name_c: "c".into() },
        ),
        other: A {
            name_a: "a2".into(),
        },
    };

    let mut de = Deserializer::new_from_reader(in_xml.as_bytes()).non_contiguous_seq_elements(true);
    let actual = Collection::deserialize(&mut de).unwrap();

    assert_eq!(should_be, actual);
}

/// Ensure that identically-named elements at different depths are not deserialized as if they were
/// at the same depth.
#[test]
fn nested_collection_repeated_elements() {
    #[derive(Debug, Deserialize, PartialEq)]
    struct OuterCollection {
        a: Vec<A>,
        inner: Inner,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct Inner {
        a: A,
    }

    #[derive(Debug, Deserialize, PartialEq)]
    struct A {
        name: String,
    }

    init_logger();

    let in_xml = r#"
        <collection>
            <a name="a1" />
            <inner>
                <a name="a2" />
            </inner>
            <a name="a3" />
        </collection>
    "#;

    let should_be = OuterCollection {
        a: vec![A { name: "a1".into() }, A { name: "a3".into() }],
        inner: Inner {
            a: A { name: "a2".into() },
        },
    };

    let mut de = Deserializer::new_from_reader(in_xml.as_bytes()).non_contiguous_seq_elements(true);
    let actual = OuterCollection::deserialize(&mut de).unwrap();

    assert_eq!(should_be, actual);
}
