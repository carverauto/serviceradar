use proc_macro2::Span;
use quote::quote;
use syn::{Ident, Lifetime};

pub fn derive_tostatic(s: synstructure::Structure) -> proc_macro2::TokenStream {
    let ast = s.ast();

    let debug_derive = ast.attrs.iter().any(|attr| {
        attr.meta
            .path()
            .is_ident(&Ident::new("debug_derive", Span::call_site()))
    });

    // if deriving a struct, there will be only one variant
    // for enums, this will iterate on each variant
    let body = s.each_variant(|vi| {
        // bindings can be empty for unit variants
        let instrs = vi
            .bindings()
            .iter()
            .enumerate()
            .fold(quote! {}, |acc, (idx, bi)| {
                let ident = Ident::new(&format!("_{idx}"), Span::call_site());
                quote! { #acc let #ident = #bi.to_static(); }
            });
        // use construct() to handle possible cases (unit/named/unnamed)
        let c = vi.construct(|_f, i| {
            let ident = Ident::new(&format!("_{i}"), Span::call_site());
            quote! { #ident }
        });
        quote! { #instrs #c }
    });

    let struct_ident = &ast.ident;

    // check if struct has lifetimes
    let static_token = match ast.generics.lifetimes().count() {
        0 => None,
        1 => {
            let lt = Lifetime::new("'static", Span::call_site());
            Some(quote! {<#lt>})
        }
        _ => {
            let lt_static = Lifetime::new("'static", Span::call_site());
            let lts = ast.generics.lifetimes().map(|_| lt_static.clone());
            Some(quote! {<#(#lts),*>})
        }
    };

    let ts = s.gen_impl(quote! {
        gen impl asn1_rs::ToStatic for @Self {
            type Owned = #struct_ident #static_token;

            fn to_static(&self) -> Self::Owned {
                match *self {
                    #body
                }
            }
        }
    });
    if debug_derive {
        eprintln!("TS: {ts}");
    }
    ts
}
