use syn::{
    parse::{
        Parse,
        ParseStream,
        Result,
    },
    Expr,
    ExprClosure,
    LitStr,
    Token,
};

/// Wrapping of the two arguments given to one of the
/// `regex_is_match`, `regex_find`, or `regex_captures`
/// macros
pub(crate) struct RexValArgs {
    pub regex_str: LitStr,
    pub value: Expr, // this expression is (or produces) the text to search or check
}

impl Parse for RexValArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let regex_str = input.parse::<LitStr>()?;
        input.parse::<Token![,]>()?;
        let value = input.parse::<Expr>()?;
        let _ = input.parse::<Token![,]>(); // allow a trailing comma
        Ok(RexValArgs { regex_str, value })
    }
}

/// Wrapping of the three arguments given to the
/// `regex_replace` and `regex_replace_all` macros
pub(crate) struct ReplaceArgs {
    pub regex_str: LitStr,
    pub value: Expr,
    pub replacer: MaybeFun,
}

pub(crate) enum MaybeFun {
    Fun(ExprClosure),
    Expr(Expr),
}

impl Parse for ReplaceArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let regex_str = input.parse::<LitStr>()?;
        input.parse::<Token![,]>()?;
        let value = input.parse::<Expr>()?;
        input.parse::<Token![,]>()?;
        // we try as a closure before, and as a general expr if
        // it doesn't work out
        let replacer = if let Ok(fun) = input.parse::<ExprClosure>() {
            MaybeFun::Fun(fun)
        } else {
            MaybeFun::Expr(input.parse::<Expr>()?)
        };
        let _ = input.parse::<Token![,]>(); // allow a trailing comma
        Ok(ReplaceArgs {
            regex_str,
            value,
            replacer,
        })
    }
}

/// Wrapping of the arguments given to a `regex_if` macro
pub(crate) struct RexIfArgs {
    pub regex_str: LitStr,
    pub value: Expr, // this expression is (or produces) the text to search or check
    pub then: Expr,
}

impl Parse for RexIfArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let regex_str = input.parse::<LitStr>()?;
        input.parse::<Token![,]>()?;
        let value = input.parse::<Expr>()?;
        input.parse::<Token![,]>()?;
        let then = input.parse::<Expr>()?;
        let _ = input.parse::<Token![,]>(); // allow a trailing comma
        Ok(Self {
            regex_str,
            value,
            then,
        })
    }
}

/// Wrapping of the arguments given to a `regex_switch` macro
pub(crate) struct RexSwitchArgs {
    pub value: Expr, // this expression is (or produces) the text to search or check
    pub arms: Vec<RexSwitchArmArgs>,
}
pub(crate) struct RexSwitchArmArgs {
    pub regex_str: LitStr,
    pub then: Expr,
}

impl Parse for RexSwitchArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let value = input.parse::<Expr>()?;
        input.parse::<Token![,]>()?;
        let mut arms = Vec::new();
        loop {
            let lookahead = input.lookahead1();
            if lookahead.peek(LitStr) {
                let arm = input.parse::<RexSwitchArmArgs>()?;
                arms.push(arm);
            } else {
                break;
            }
        }
        Ok(Self {
            value,
            arms,
        })
    }
}
impl Parse for RexSwitchArmArgs {
    fn parse(input: ParseStream<'_>) -> Result<Self> {
        let regex_str = input.parse::<LitStr>()?;
        input.parse::<Token![=>]>()?;
        let then = input.parse::<Expr>()?;
        let _ = input.parse::<Token![,]>(); // allow a trailing comma
        Ok(Self {
            regex_str,
            then,
        })
    }
}
