use proc_macro2::TokenStream;
use quote::quote;
use syn::{
    visit_mut::{self, visit_item_mut, visit_path_segment_mut, VisitMut},
    Expr, ExprBlock, File, GenericArgument, GenericParam, Item, PathArguments, PathSegment,
    ReturnType, Signature, Stmt, Type, TypeParamBound, WherePredicate,
};

pub struct ReplaceGenericType<'a> {
    generic_type: &'a str,
    arg_type: &'a PathSegment,
}

impl<'a> ReplaceGenericType<'a> {
    pub fn new(generic_type: &'a str, arg_type: &'a PathSegment) -> Self {
        Self {
            generic_type,
            arg_type,
        }
    }

    pub fn replace_generic_type(item: &mut Item, generic_type: &'a str, arg_type: &'a PathSegment) {
        let mut s = Self::new(generic_type, arg_type);
        s.visit_item_mut(item);
    }
}

impl<'a> VisitMut for ReplaceGenericType<'a> {
    fn visit_item_mut(&mut self, i: &mut Item) {
        if let Item::Fn(item_fn) = i {
            // remove generic type from generics <T, F>
            let args = item_fn
                .sig
                .generics
                .params
                .iter()
                .filter_map(|param| {
                    if let GenericParam::Type(type_param) = &param {
                        if type_param.ident.to_string().eq(self.generic_type) {
                            None
                        } else {
                            Some(param)
                        }
                    } else {
                        Some(param)
                    }
                })
                .collect::<Vec<_>>();
            item_fn.sig.generics.params = args.into_iter().cloned().collect();

            // remove generic type from where clause
            if let Some(where_clause) = &mut item_fn.sig.generics.where_clause {
                let new_where_clause = where_clause
                    .predicates
                    .iter()
                    .filter_map(|predicate| {
                        if let WherePredicate::Type(predicate_type) = predicate {
                            if let Type::Path(p) = &predicate_type.bounded_ty {
                                if p.path.segments[0].ident.to_string().eq(self.generic_type) {
                                    None
                                } else {
                                    Some(predicate)
                                }
                            } else {
                                Some(predicate)
                            }
                        } else {
                            Some(predicate)
                        }
                    })
                    .collect::<Vec<_>>();

                where_clause.predicates = new_where_clause.into_iter().cloned().collect();
            };
        }
        visit_item_mut(self, i)
    }
    fn visit_path_segment_mut(&mut self, i: &mut PathSegment) {
        // replace generic type with target type
        if i.ident.to_string().eq(&self.generic_type) {
            *i = self.arg_type.clone();
        }
        visit_path_segment_mut(self, i);
    }
}

pub struct AsyncAwaitRemoval;

impl AsyncAwaitRemoval {
    pub fn remove_async_await(&mut self, item: TokenStream) -> TokenStream {
        let mut syntax_tree: File = syn::parse(item.into()).unwrap();
        self.visit_file_mut(&mut syntax_tree);
        quote!(#syntax_tree)
    }
}

impl VisitMut for AsyncAwaitRemoval {
    fn visit_expr_mut(&mut self, node: &mut Expr) {
        // Unwrap `Box::pin(async {..})` / `Box::new(async {..})` BEFORE recursing,
        // so the inner async block remains visible to the Async match-arm below.
        if let Some(unwrapped) = unwrap_box_call_with_async(node) {
            *node = unwrapped;
        }

        // Delegate to the default impl to visit nested expressions.
        visit_mut::visit_expr_mut(self, node);

        match node {
            Expr::Await(expr) => *node = (*expr.base).clone(),

            Expr::Async(expr) => {
                let inner = &expr.block;
                let sync_expr = if let [Stmt::Expr(expr, None)] = inner.stmts.as_slice() {
                    // remove useless braces when there is only one statement
                    expr.clone()
                } else {
                    Expr::Block(ExprBlock {
                        attrs: expr.attrs.clone(),
                        block: inner.clone(),
                        label: None,
                    })
                };
                *node = sync_expr;
            }
            _ => {}
        }
    }

    fn visit_signature_mut(&mut self, sig: &mut Signature) {
        // rewrite `-> impl Future<Output = T> + ...`,
        // `-> Box<dyn Future<Output = T> + ...>`,
        // `-> Pin<Box<dyn Future<Output = T> + ...>>` to `-> T`
        if let ReturnType::Type(arrow, ty) = &sig.output {
            if let Some(inner) = extract_future_output(ty) {
                sig.output = ReturnType::Type(*arrow, Box::new(inner));
            }
        }
        visit_mut::visit_signature_mut(self, sig);
    }

    fn visit_item_mut(&mut self, i: &mut Item) {
        // find generic parameter of Future and replace it with its Output type
        if let Item::Fn(item_fn) = i {
            let mut inputs: Vec<(String, PathSegment)> = vec![];

            // generic params: <T:Future<Output=()>, F>
            for param in &item_fn.sig.generics.params {
                // generic param: T:Future<Output=()>
                if let GenericParam::Type(type_param) = param {
                    let generic_type_name = type_param.ident.to_string();

                    // bound: Future<Output=()>
                    for bound in &type_param.bounds {
                        inputs.extend(search_trait_bound(&generic_type_name, bound));
                    }
                }
            }

            if let Some(where_clause) = &item_fn.sig.generics.where_clause {
                for predicate in &where_clause.predicates {
                    if let WherePredicate::Type(predicate_type) = predicate {
                        let generic_type_name = if let Type::Path(p) = &predicate_type.bounded_ty {
                            p.path.segments[0].ident.to_string()
                        } else {
                            panic!("Please submit an issue");
                        };

                        for bound in &predicate_type.bounds {
                            inputs.extend(search_trait_bound(&generic_type_name, bound));
                        }
                    }
                }
            }

            for (generic_type_name, path_seg) in &inputs {
                ReplaceGenericType::replace_generic_type(i, generic_type_name, path_seg);
            }
        }
        visit_item_mut(self, i);
    }
}

/// Extract `T` from any of:
/// - `impl Future<Output = T> + ...`
/// - `Box<dyn Future<Output = T> + ...>`
/// - `Pin<Box<dyn Future<Output = T> + ...>>`
/// Paths are matched by last segment name only, so `std::pin::Pin`,
/// `core::pin::Pin`, etc. all match.
fn extract_future_output(ty: &Type) -> Option<Type> {
    match ty {
        Type::ImplTrait(impl_trait) => extract_future_output_from_bounds(impl_trait.bounds.iter()),
        Type::TraitObject(trait_obj) => extract_future_output_from_bounds(trait_obj.bounds.iter()),
        Type::Path(p) => {
            let seg = p.path.segments.last()?;
            let name = seg.ident.to_string();
            let PathArguments::AngleBracketed(args) = &seg.arguments else {
                return None;
            };
            match name.as_str() {
                "Pin" | "Box" => args.args.iter().find_map(|arg| {
                    if let GenericArgument::Type(inner) = arg {
                        extract_future_output(inner)
                    } else {
                        None
                    }
                }),
                _ => None,
            }
        }
        _ => None,
    }
}

fn extract_future_output_from_bounds<'a>(
    bounds: impl Iterator<Item = &'a TypeParamBound>,
) -> Option<Type> {
    for bound in bounds {
        let TypeParamBound::Trait(trait_bound) = bound else {
            continue;
        };
        let Some(seg) = trait_bound.path.segments.last() else {
            continue;
        };
        if seg.ident.to_string() != "Future" {
            continue;
        }
        let PathArguments::AngleBracketed(args) = &seg.arguments else {
            continue;
        };
        for arg in &args.args {
            if let GenericArgument::AssocType(assoc) = arg {
                if assoc.ident.to_string() == "Output" {
                    return Some(assoc.ty.clone());
                }
            }
        }
    }
    None
}

/// If `node` is `Box::pin(<async block>)` or `Box::new(<async block>)`,
/// return the async block. Path is matched on the last two segments being
/// `Box` then `pin`/`new`, so qualified paths like `::std::boxed::Box::pin`
/// also match.
fn unwrap_box_call_with_async(node: &Expr) -> Option<Expr> {
    let Expr::Call(call) = node else { return None };
    let Expr::Path(path_expr) = call.func.as_ref() else {
        return None;
    };
    let segs = &path_expr.path.segments;
    if segs.len() < 2 {
        return None;
    }
    let last = segs[segs.len() - 1].ident.to_string();
    let second_last = segs[segs.len() - 2].ident.to_string();
    if second_last != "Box" || (last != "pin" && last != "new") {
        return None;
    }
    if call.args.len() != 1 {
        return None;
    }
    if !matches!(&call.args[0], Expr::Async(_)) {
        return None;
    }
    Some(call.args[0].clone())
}

fn search_trait_bound(
    generic_type_name: &str,
    bound: &TypeParamBound,
) -> Vec<(String, PathSegment)> {
    let mut inputs = vec![];

    if let TypeParamBound::Trait(trait_bound) = bound {
        let segment = &trait_bound.path.segments[trait_bound.path.segments.len() - 1];
        let name = segment.ident.to_string();
        if name.eq("Future") {
            // match Future<Output=Type>
            if let PathArguments::AngleBracketed(args) = &segment.arguments {
                // binding: Output=Type
                if let GenericArgument::AssocType(binding) = &args.args[0] {
                    if let Type::Path(p) = &binding.ty {
                        inputs.push((generic_type_name.to_owned(), p.path.segments[0].clone()));
                    }
                }
            }
        }
    }
    inputs
}
