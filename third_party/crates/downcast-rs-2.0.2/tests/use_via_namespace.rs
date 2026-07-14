extern crate downcast_rs;

#[test]
fn test() {
    use downcast_rs::Downcast;
    #[allow(dead_code)]
    trait Trait: Downcast {}
    downcast_rs::impl_downcast!(Trait);
}
