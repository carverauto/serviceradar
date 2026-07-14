use alloc::borrow::Cow;
use alloc::string::ToString;

/// Common trait for objects that can be transformed to a `'static` version of `self`
pub trait ToStatic {
    type Owned: 'static;
    fn to_static(&self) -> Self::Owned;
}

impl ToStatic for Cow<'_, str> {
    type Owned = Cow<'static, str>;
    fn to_static(&self) -> <Self as ToStatic>::Owned {
        Cow::Owned(self.to_string())
    }
}

impl ToStatic for Cow<'_, [u8]> {
    type Owned = Cow<'static, [u8]>;
    fn to_static(&self) -> <Self as ToStatic>::Owned {
        Cow::Owned(self.to_vec())
    }
}

macro_rules! impl_tostatic_primitive {
    ($t:ty) => {
        impl ToStatic for $t {
            type Owned = $t;
            fn to_static(&self) -> <Self as ToStatic>::Owned {
                self.clone()
            }
        }
    };
    ($t:ty => $to:ty, $closure:expr) => {
        impl ToStatic for $t {
            type Owned = $to;
            fn to_static(&self) -> <Self as ToStatic>::Owned {
                let f: &dyn Fn(&Self) -> $to = &$closure;
                f(self)
            }
        }
    };
    (I $($types: ty)+) => {
        $(
            impl_tostatic_primitive!($types);
        )*
    };
}

impl_tostatic_primitive!(bool);
impl_tostatic_primitive!(I i8 i16 i32 i64 i128 isize);
impl_tostatic_primitive!(I u8 u16 u32 u64 u128 usize);

impl<T> ToStatic for &'_ T
where
    T: ToStatic,
{
    type Owned = T::Owned;

    fn to_static(&self) -> Self::Owned {
        (*self).to_static()
    }
}

impl<T> ToStatic for Option<T>
where
    T: ToStatic,
{
    type Owned = Option<T::Owned>;

    fn to_static(&self) -> Self::Owned {
        self.as_ref().map(ToStatic::to_static)
    }
}

#[cfg(feature = "std")]
const _: () = {
    impl_tostatic_primitive!(I String);
    impl_tostatic_primitive!(str => String, |s| s.to_string());

    impl<T> ToStatic for Box<T>
    where
        T: ToStatic,
    {
        type Owned = Box<T::Owned>;

        fn to_static(&self) -> Self::Owned {
            Box::new(self.as_ref().to_static())
        }
    }
};
