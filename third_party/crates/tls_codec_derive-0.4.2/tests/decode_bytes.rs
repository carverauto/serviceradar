use tls_codec::{DeserializeBytes, SerializeBytes, Size};
use tls_codec_derive::{TlsDeserializeBytes, TlsSerializeBytes, TlsSize};

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, PartialEq, Debug)]
#[repr(u16)]
pub enum ExtensionType {
    Reserved = 0,
    Capabilities = 1,
    Lifetime = 2,
    KeyId = 3,
    ParentHash = 4,
    RatchetTree = 5,
    SomethingElse = 500,
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
pub struct ExtensionStruct {
    extension_type: ExtensionType,
    extension_data: Vec<u8>,
    additional_data: Option<Vec<u8>>,
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
pub struct TupleStruct(ExtensionStruct, u8);

#[derive(TlsSerializeBytes, TlsSize, Debug, Clone)]
struct SomeValue {
    val: Vec<u8>,
}

#[test]
fn simple_enum() {
    let serialized = ExtensionType::KeyId.tls_serialize().unwrap();
    let (deserialized, rest) = ExtensionType::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, ExtensionType::KeyId);
    assert!(rest.is_empty());
    let serialized = ExtensionType::SomethingElse.tls_serialize().unwrap();
    let (deserialized, rest) = ExtensionType::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, ExtensionType::SomethingElse);
    assert!(rest.is_empty());
}

#[test]
fn simple_struct() {
    let extension = ExtensionStruct {
        extension_type: ExtensionType::KeyId,
        extension_data: vec![1, 2, 3, 4, 5],
        additional_data: None,
    };
    let serialized = extension.tls_serialize().unwrap();
    let (deserialized, rest) = ExtensionStruct::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, extension);
    assert!(rest.is_empty());
}

#[test]
fn tuple_struct() {
    let ext = ExtensionStruct {
        extension_type: ExtensionType::KeyId,
        extension_data: vec![1, 2, 3, 4, 5],
        additional_data: None,
    };
    let x = TupleStruct(ext, 6);
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) = TupleStruct::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[test]
fn byte_arrays() {
    let x = [0u8, 1, 2, 3];
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) = <[u8; 4]>::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
struct Custom {
    #[tls_codec(with = "custom")]
    values: Vec<u8>,
    a: u8,
}

mod custom {
    use tls_codec::{DeserializeBytes, SerializeBytes, Size};

    pub fn tls_serialized_len(v: &[u8]) -> usize {
        v.tls_serialized_len()
    }

    pub fn tls_serialize(v: &[u8]) -> Result<Vec<u8>, tls_codec::Error> {
        v.tls_serialize()
    }

    pub fn tls_deserialize_bytes<T: DeserializeBytes>(
        bytes: &[u8],
    ) -> Result<(T, &[u8]), tls_codec::Error> {
        T::tls_deserialize_bytes(bytes)
    }
}

#[test]
fn custom() {
    let x = Custom {
        values: vec![0, 1, 2],
        a: 3,
    };
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![3, 0, 1, 2, 3], serialized);
    let (deserialized, rest) = Custom::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
#[repr(u8)]
enum EnumWithTupleVariant {
    A(u8, u32),
}

#[test]
fn enum_with_tuple_variant() {
    let x = EnumWithTupleVariant::A(3, 4);
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) = EnumWithTupleVariant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
#[repr(u8)]
enum EnumWithStructVariant {
    A { foo: u8, bar: u32 },
}

#[test]
fn enum_with_struct_variant() {
    let x = EnumWithStructVariant::A { foo: 3, bar: 4 };
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) = EnumWithStructVariant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
#[repr(u16)]
enum EnumWithDataAndDiscriminant {
    #[tls_codec(discriminant = 3)]
    A(u8),
    B,
}

#[test]
fn enum_with_data_and_discriminant() {
    let x = EnumWithDataAndDiscriminant::A(4);
    let serialized = x.tls_serialize().unwrap();

    let (deserialized, rest) =
        EnumWithDataAndDiscriminant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[test]
fn discriminant_is_incremented_implicitly() {
    let x = EnumWithDataAndDiscriminant::B;
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) =
        EnumWithDataAndDiscriminant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

mod discriminant {
    pub mod test {
        pub mod constant {
            pub const TEST_CONST: u8 = 3;
        }
        pub mod enum_val {
            pub enum Test {
                Potato = 0x0004,
            }
        }
    }
}

#[derive(Debug, PartialEq, TlsSerializeBytes, TlsDeserializeBytes, TlsSize)]
#[repr(u16)]
enum EnumWithDataAndConstDiscriminant {
    #[tls_codec(discriminant = "discriminant::test::constant::TEST_CONST")]
    A(u8),
    #[tls_codec(discriminant = "discriminant::test::enum_val::Test::Potato")]
    B,
    #[tls_codec(discriminant = 12)]
    C,
}

#[test]
fn enum_with_data_and_const_discriminant() {
    let x = EnumWithDataAndConstDiscriminant::A(4);
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 3, 4], serialized);
    let (deserialized, rest) =
        EnumWithDataAndConstDiscriminant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());

    let x = EnumWithDataAndConstDiscriminant::B;
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) =
        EnumWithDataAndConstDiscriminant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());

    let x = EnumWithDataAndConstDiscriminant::C;
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) =
        EnumWithDataAndConstDiscriminant::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[derive(TlsSerializeBytes, TlsDeserializeBytes, TlsSize, Debug, PartialEq)]
#[repr(u8)]
enum EnumWithCustomSerializedField {
    A(#[tls_codec(with = "custom")] Vec<u8>),
}

#[test]
fn enum_with_custom_serialized_field() {
    let x = EnumWithCustomSerializedField::A(vec![1, 2, 3]);
    let serialized = x.tls_serialize().unwrap();
    let (deserialized, rest) =
        EnumWithCustomSerializedField::tls_deserialize_bytes(&serialized).unwrap();
    assert_eq!(deserialized, x);
    assert!(rest.is_empty());
}

#[test]
fn that_skip_attribute_on_struct_works() {
    fn test<T>(test: T, expected: T)
    where
        T: DeserializeBytes + std::fmt::Debug + PartialEq + SerializeBytes + Size,
    {
        let serialized = test.tls_serialize().unwrap();
        let (deserialized, rest) = T::tls_deserialize_bytes(&serialized).unwrap();
        assert_eq!(deserialized, expected);
        assert!(rest.is_empty());
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsDeserializeBytes, TlsSize)]
    struct StructWithSkip1 {
        #[tls_codec(skip)]
        a: u8,
        b: u8,
        c: u8,
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsDeserializeBytes, TlsSize)]
    struct StructWithSkip2 {
        a: u8,
        #[tls_codec(skip)]
        b: u8,
        c: u8,
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsDeserializeBytes, TlsSize)]
    struct StructWithSkip3 {
        a: u8,
        b: u8,
        #[tls_codec(skip)]
        c: u8,
    }

    test(
        StructWithSkip1 {
            a: 123,
            b: 13,
            c: 42,
        },
        StructWithSkip1 {
            a: Default::default(),
            b: 13,
            c: 42,
        },
    );
    test(
        StructWithSkip2 {
            a: 123,
            b: 13,
            c: 42,
        },
        StructWithSkip2 {
            a: 123,
            b: Default::default(),
            c: 42,
        },
    );
    test(
        StructWithSkip3 {
            a: 123,
            b: 13,
            c: 42,
        },
        StructWithSkip3 {
            a: 123,
            b: 13,
            c: Default::default(),
        },
    );
}
