use std::borrow::Cow;

use asn1_rs::*;

#[derive(ToStatic)]
pub struct Unit;

#[test]
fn derive_unit_tostatic() {
    let unit = Unit;

    let _static = unit.to_static();
    assert_static_lifetime(&unit);
}

#[derive(ToStatic)]
//#[debug_derive]
pub struct Unnamed<'a>(pub Cow<'a, str>);

#[test]
fn derive_unnamed_tostatic() {
    let s = Cow::Borrowed("test");
    let unnamed = Unnamed(s);

    let _static = unnamed.to_static();
    assert!(matches! { _static.0, Cow::Owned(_) });
}

#[derive(ToStatic)]
//#[debug_derive]
pub struct Named<'a> {
    cow: Cow<'a, str>,
}

#[derive(ToStatic)]
//#[debug_derive]
pub struct Embed<'a> {
    a: Cow<'a, str>,
    n: Named<'a>,
}

#[test]
fn derive_named_tostatic() {
    let s = Cow::Borrowed("test");
    let named1 = Named { cow: s };

    let _static1 = named1.to_static();
    assert_static_lifetime(&_static1);
    assert!(matches! { _static1.cow, Cow::Owned(_) });

    let s2 = Cow::Borrowed("test2");
    let named2 = Embed { a: s2, n: named1 };

    let _static2 = named2.to_static();
    assert_static_lifetime(&_static2);
    assert!(matches! { _static2.a, Cow::Owned(_) });
    assert!(matches! { _static2.n.cow, Cow::Owned(_) });
}

#[derive(ToStatic)]
//#[debug_derive]
pub enum MyEnum0 {
    Variant0,
    Variant1(u32),
    Variant2 { a: u32, b: u32 },
}

fn assert_static_lifetime<T>(_arg: &T)
where
    T: 'static,
{
}
