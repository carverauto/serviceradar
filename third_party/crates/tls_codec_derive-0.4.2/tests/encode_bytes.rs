use tls_codec::{SerializeBytes, Size};
use tls_codec_derive::{TlsSerializeBytes, TlsSize};

#[derive(TlsSerializeBytes, TlsSize, Debug)]
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

#[derive(TlsSerializeBytes, TlsSize, Debug)]
pub struct ExtensionStruct {
    extension_type: ExtensionType,
    extension_data: Vec<u8>,
    additional_data: Option<Vec<u8>>,
}

#[derive(TlsSerializeBytes, TlsSize, Debug)]
pub struct TupleStruct(ExtensionStruct, u8);

#[derive(TlsSerializeBytes, TlsSize, Debug)]
pub struct StructWithLifetime<'a> {
    value: &'a Vec<u8>,
}

#[derive(TlsSerializeBytes, TlsSize, Debug, Clone)]
struct SomeValue {
    val: Vec<u8>,
}

#[test]
fn lifetime_struct() {
    let value = vec![7u8; 33];
    let s = StructWithLifetime { value: &value };
    let serialized_s = s.tls_serialize().unwrap();
    assert_eq!(serialized_s, value.tls_serialize().unwrap());
}

#[test]
fn simple_enum() {
    let serialized = ExtensionType::KeyId.tls_serialize().unwrap();
    assert_eq!(vec![0, 3], serialized);
    let serialized = ExtensionType::SomethingElse.tls_serialize().unwrap();
    assert_eq!(vec![1, 244], serialized);
}

#[test]
fn simple_struct() {
    let extension = ExtensionStruct {
        extension_type: ExtensionType::KeyId,
        extension_data: vec![1, 2, 3, 4, 5],
        additional_data: None,
    };
    let serialized = extension.tls_serialize().unwrap();
    assert_eq!(vec![0, 3, 5, 1, 2, 3, 4, 5, 0], serialized);
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
    assert_eq!(vec![0, 3, 5, 1, 2, 3, 4, 5, 0, 6], serialized);
}

#[test]
fn byte_arrays() {
    let x = [0u8, 1, 2, 3];
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 1, 2, 3], serialized);
}

#[test]
fn lifetimes() {
    let x = vec![1, 2, 3, 4];
    let s = StructWithLifetime { value: &x };
    let serialized = s.tls_serialize().unwrap();
    assert_eq!(vec![4, 1, 2, 3, 4], serialized);

    pub fn do_some_serializing(val: &StructWithLifetime) -> Vec<u8> {
        val.tls_serialize().unwrap()
    }
    let serialized = do_some_serializing(&s);
    assert_eq!(vec![4, 1, 2, 3, 4], serialized);
}

#[derive(TlsSerializeBytes, TlsSize)]
struct Custom {
    #[tls_codec(with = "custom")]
    values: Vec<u8>,
    a: u8,
}

mod custom {
    use tls_codec::{SerializeBytes, Size};

    pub fn tls_serialized_len(v: &[u8]) -> usize {
        v.tls_serialized_len()
    }

    pub fn tls_serialize(v: &[u8]) -> Result<Vec<u8>, tls_codec::Error> {
        v.tls_serialize()
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
}

#[derive(TlsSerializeBytes, TlsSize)]
struct OptionalMemberRef<'a> {
    optional_member: Option<&'a u32>,
    ref_optional_member: &'a Option<&'a u32>,
    ref_vector: &'a Vec<u16>,
}

#[test]
fn optional_member() {
    let m = 6;
    let v = vec![1, 2, 3];
    let x = OptionalMemberRef {
        optional_member: Some(&m),
        ref_optional_member: &None,
        ref_vector: &v,
    };
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![1, 0, 0, 0, 6, 0, 6, 0, 1, 0, 2, 0, 3], serialized);
}

#[derive(TlsSerializeBytes, TlsSize)]
#[repr(u8)]
enum EnumWithTupleVariant {
    A(u8, u32),
}

#[test]
fn enum_with_tuple_variant() {
    let x = EnumWithTupleVariant::A(3, 4);
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 3, 0, 0, 0, 4], serialized);
}

#[derive(TlsSerializeBytes, TlsSize)]
#[repr(u8)]
enum EnumWithStructVariant {
    A { foo: u8, bar: u32 },
}

#[test]
fn enum_with_struct_variant() {
    let x = EnumWithStructVariant::A { foo: 3, bar: 4 };
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 3, 0, 0, 0, 4], serialized);
}

#[derive(TlsSerializeBytes, TlsSize)]
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
    assert_eq!(vec![0, 3, 4], serialized);
}

#[test]
fn discriminant_is_incremented_implicitly() {
    let x = EnumWithDataAndDiscriminant::B;
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 4], serialized);
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

#[derive(Debug, PartialEq, TlsSerializeBytes, TlsSize)]
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
    let serialized = EnumWithDataAndConstDiscriminant::A(4)
        .tls_serialize()
        .unwrap();
    assert_eq!(vec![0, 3, 4], serialized);
    let serialized = EnumWithDataAndConstDiscriminant::B.tls_serialize().unwrap();
    assert_eq!(vec![0, 4], serialized);
    let serialized = EnumWithDataAndConstDiscriminant::C.tls_serialize().unwrap();
    assert_eq!(vec![0, 12], serialized);
}

#[derive(TlsSerializeBytes, TlsSize)]
#[repr(u8)]
enum EnumWithCustomSerializedField {
    A(#[tls_codec(with = "custom")] Vec<u8>),
}

#[test]
fn enum_with_custom_serialized_field() {
    let x = EnumWithCustomSerializedField::A(vec![1, 2, 3]);
    let serialized = x.tls_serialize().unwrap();
    assert_eq!(vec![0, 3, 1, 2, 3], serialized);
}

#[test]
fn that_skip_attribute_on_struct_works() {
    fn test<T>(test: T, expected: &[u8])
    where
        T: std::fmt::Debug + PartialEq + SerializeBytes + Size,
    {
        // Check precalculated length.
        assert_eq!(test.tls_serialized_len(), expected.len());

        // Check serialization.
        assert_eq!(test.tls_serialize().unwrap(), expected);
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsSize)]
    struct StructWithSkip1 {
        #[tls_codec(skip)]
        a: u8,
        b: u8,
        c: u8,
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsSize)]
    struct StructWithSkip2 {
        a: u8,
        #[tls_codec(skip)]
        b: u8,
        c: u8,
    }

    #[derive(Debug, PartialEq, TlsSerializeBytes, TlsSize)]
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
        &[13, 42],
    );
    test(
        StructWithSkip2 {
            a: 123,
            b: 13,
            c: 42,
        },
        &[123, 42],
    );
    test(
        StructWithSkip3 {
            a: 123,
            b: 13,
            c: 42,
        },
        &[123, 13],
    );
}
