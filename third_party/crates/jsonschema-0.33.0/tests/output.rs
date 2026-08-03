use serde_json::json;
use test_case::test_case;

#[test_case{
    &json!({"allOf": [{"type": "string", "typeannotation": "value"}, {"maxLength": 20, "lengthannotation": "value"}]}),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/allOf/0",
                "instanceLocation": "",
                "annotations": {
                    "typeannotation": "value"
                }
            },
            {
                "keywordLocation": "/allOf/1",
                "instanceLocation": "",
                "annotations": { "lengthannotation": "value" } }
        ]
    }); "valid allOf"
}]
#[test_case{
    &json!({"allOf": [{"type": "array"}, {"maxLength": 4}]}),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/allOf/0/type",
                "instanceLocation": "",
                "error": "\"some string\" is not of type \"array\""
            },
            {
                "keywordLocation": "/allOf/1/maxLength",
                "instanceLocation": "",
                "error": "\"some string\" is longer than 4 characters"
            }
        ]
    }); "invalid allOf"
}]
#[test_case{
    &json!({"allOf": [{"type": "string", "typeannotation": "value"}]}),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/allOf/0",
                "instanceLocation": "",
                "annotations": {
                    "typeannotation": "value"
                }
            }
        ]
    }); "valid single value allOf"
}]
#[test_case{
    &json!({"allOf": [{"type": "array"}]}),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/allOf/0/type",
                "instanceLocation": "",
                "error": "\"some string\" is not of type \"array\""
            }
        ]
    }); "invalid single value allOf"
}]
#[test_case{
    &json!({"anyOf": [{"type": "string", "someannotation": "value"}, {"maxLength": 4}, {"minLength": 1}]}),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/anyOf/0",
                "instanceLocation": "",
                "annotations": {
                    "someannotation": "value"
                }
            }
        ]
    }); "valid anyOf"
}]
#[test_case{
    &json!({"anyOf": [{"type": "object"}, {"maxLength": 4}]}),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/anyOf/0/type",
                "instanceLocation": "",
                "error": "\"some string\" is not of type \"object\""
            },
            {
                "keywordLocation": "/anyOf/1/maxLength",
                "instanceLocation": "",
                "error": "\"some string\" is longer than 4 characters"
            }
        ]
    }); "invalid anyOf"
}]
#[test_case{
    &json!({"oneOf": [{"type": "object", "someannotation": "somevalue"}, {"type": "string"}]}),
    &json!({"somekey": "some value"}),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/oneOf/0",
                "instanceLocation": "",
                "annotations": {
                    "someannotation": "somevalue"
                }
            }
        ]
    }); "valid oneOf"
}]
#[test_case{
    &json!({"oneOf": [{"type": "object"}, {"maxLength": 4}]}),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/oneOf/0/type",
                "instanceLocation": "",
                "error": "\"some string\" is not of type \"object\""
            },
            {
                "keywordLocation": "/oneOf/1/maxLength",
                "instanceLocation": "",
                "error": "\"some string\" is longer than 4 characters"
            }
        ]
    }); "invalid oneOf"
}]
#[test_case{
    &json!({"oneOf": [{"type": "string"}, {"maxLength": 40}]}),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/oneOf",
                "instanceLocation": "",
                "error": "more than one subschema succeeded"
            },
        ]
    }); "invalid oneOf multiple successes"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 20, "thenannotation": "thenvalue"}
    }),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/if",
                "instanceLocation": "",
                "annotations": {
                    "ifannotation": "ifvalue"
                }
            },
            {
                "keywordLocation": "/then",
                "instanceLocation": "",
                "annotations": {
                    "thenannotation": "thenvalue"
                }
            },
        ]
    }); "valid if-then"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 4, "thenannotation": "thenvalue"}
    }),
    &json!("some string"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/then/maxLength",
                "instanceLocation": "",
                "error": "\"some string\" is longer than 4 characters"
            },
        ]
    }); "invalid if-then"
}]
#[test_case{
    &json!({
        "if": {"type": "object", "ifannotation": "ifvalue"},
        "else": {"maxLength": 20, "elseannotation": "elsevalue"}
    }),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/else",
                "instanceLocation": "",
                "annotations": {
                    "elseannotation": "elsevalue"
                }
            },
        ]
    }); "valid if-else"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "else": {"type": "array", "elseannotation": "elsevalue"}
    }),
    &json!({"some": "object"}),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/else/type",
                "instanceLocation": "",
                "error": "{\"some\":\"object\"} is not of type \"array\""
            },
        ]
    }); "invalid if-else"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 20, "thenannotation": "thenvalue"},
        "else": {"type": "number", "elseannotation": "elsevalue"}
    }),
    &json!("some string"),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/if",
                "instanceLocation": "",
                "annotations": {
                    "ifannotation": "ifvalue"
                }
            },
            {
                "keywordLocation": "/then",
                "instanceLocation": "",
                "annotations": {
                    "thenannotation": "thenvalue"
                }
            },
        ]
    }); "valid if-then-else then-branch"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 20, "thenannotation": "thenvalue"},
        "else": {"type": "number", "elseannotation": "elsevalue"}
    }),
    &json!(12),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/else",
                "instanceLocation": "",
                "annotations": {
                    "elseannotation": "elsevalue"
                }
            },
        ]
    }); "valid if-then-else else-branch"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 4, "thenannotation": "thenvalue"},
        "else": {"type": "number", "elseannotation": "elsevalue"}
    }),
    &json!("12345"),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/then/maxLength",
                "instanceLocation": "",
                "error": "\"12345\" is longer than 4 characters"
            },
        ] }); "invalid if-then-else then branch"
}]
#[test_case{
    &json!({
        "if": {"type": "string", "ifannotation": "ifvalue"},
        "then": {"maxLength": 20, "thenannotation": "thenvalue"},
        "else": {"type": "number", "elseannotation": "elsevalue"}
    }),
    &json!({"some": "object"}),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/else/type",
                "instanceLocation": "",
                "error": "{\"some\":\"object\"} is not of type \"number\""
            },
        ]
    }); "invalid if-then-else else branch"
}]
#[test_case{
    &json!({
        "type": "array",
        "items": {
            "type": "number",
            "annotation": "value"
        }
    }),
    &json!([1,2]),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/items",
                "instanceLocation": "",
                "annotations": true
            },
            {
                "keywordLocation": "/items",
                "instanceLocation": "/0",
                "annotations": {
                    "annotation": "value"
                }
            },
            {
                "keywordLocation": "/items",
                "instanceLocation": "/1",
                "annotations": {
                    "annotation": "value"
                }
            },
        ]
    }); "valid items"
}]
#[test_case{
    &json!({
        "type": "array",
        "items": {
            "type": "number",
            "annotation": "value"
        }
    }),
    &json!([]),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/items",
                "instanceLocation": "",
                "annotations": false
            },
        ]
    }); "valid items empty array"
}]
#[test_case{
    &json!({
        "type": "array",
        "items": {
            "type": "string",
            "annotation": "value"
        }
    }),
    &json!([1,2,"3"]),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/items/type",
                "instanceLocation": "/0",
                "error": "1 is not of type \"string\""
            },
            {
                "keywordLocation": "/items/type",
                "instanceLocation": "/1",
                "error": "2 is not of type \"string\""
            },
        ]
    }); "invalid items"
}]
#[test_case{
    &json!({
        "contains": {
            "type": "number",
            "annotation": "value",
            "maximum": 2
        }
    }),
    &json!([1,3,2]),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/contains",
                "instanceLocation": "",
                "annotations": [0, 2]
            },
            {
                "keywordLocation": "/contains",
                "instanceLocation": "/0",
                "annotations": {
                    "annotation": "value"
                }
            },
            {
                "keywordLocation": "/contains",
                "instanceLocation": "/2",
                "annotations": {
                    "annotation": "value"
                }
            }
        ]
    }); "valid contains"
}]
#[test_case{
    &json!({
        "contains": {
            "type": "number",
            "annotation": "value",
            "maximum": 2
        }
    }),
    &json!(["one"]),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/contains",
                "instanceLocation": "",
                "error": "None of [\"one\"] are valid under the given schema",
            },
        ]
    }); "invalid contains"
}]
#[test_case{
    &json!({
        "properties": {
            "name": {"type": "string", "some": "subannotation"},
            "age": {"type": "number"}
        }
    }),
    &json!({
        "name": "some name",
        "age": 10
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/properties",
                "instanceLocation": "",
                "annotations": [
                    "age",
                    "name"
                ]
            },
            {
                "keywordLocation": "/properties/name",
                "instanceLocation": "/name",
                "annotations": {
                    "some": "subannotation"
                }
            }
        ]
    }); "valid properties"
}]
#[test_case{
    &json!({
        "patternProperties": {
            "numProp(\\d+)": {"type": "number", "some": "subannotation"},
            "stringProp(\\d+)": {"type": "string"},
            "unmatchedProp\\S": {"type": "object"},
        }
    }),
    &json!({
        "numProp1": 1,
        "numProp2": 2,
        "stringProp1": "1"
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/patternProperties",
                "instanceLocation": "",
                "annotations": [
                    "numProp1",
                    "numProp2",
                    "stringProp1"
                ]
            },
            {
                "keywordLocation": "/patternProperties/numProp(\\d+)",
                "instanceLocation": "/numProp1",
                "annotations": {
                    "some": "subannotation"
                }
            },
            {
                "keywordLocation": "/patternProperties/numProp(\\d+)",
                "instanceLocation": "/numProp2",
                "annotations": {
                    "some": "subannotation"
                }
            }
        ]
    }); "valid patternProperties"
}]
#[test_case{
    &json!({
        "patternProperties": {
            "numProp(\\d+)": {"type": "number", "some": "subannotation"}
        }
    }),
    &json!({
        "numProp1": 1,
        "numProp2": 2,
        "stringProp1": "1"
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/patternProperties",
                "instanceLocation": "",
                "annotations": [
                    "numProp1",
                    "numProp2",
                ]
            },
            {
                "keywordLocation": "/patternProperties/numProp(\\d+)",
                "instanceLocation": "/numProp1",
                "annotations": {
                    "some": "subannotation"
                }
            },
            {
                "keywordLocation": "/patternProperties/numProp(\\d+)",
                "instanceLocation": "/numProp2",
                "annotations": {
                    "some": "subannotation"
                }
            }
        ]
    }); "valid single value patternProperties"
}]
#[test_case{
    &json!({
        "propertyNames": {"maxLength": 10, "some": "annotation"}
    }),
    &json!({
        "name": "some name",
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/propertyNames",
                "instanceLocation": "",
                "annotations": {"some": "annotation"}
            },
        ]
    }); "valid propertyNames"
}]
fn test_basic_output(
    schema: &serde_json::Value,
    instance: &serde_json::Value,
    expected_output: &serde_json::Value,
) {
    let validator = jsonschema::validator_for(schema).unwrap();
    let output = serde_json::to_value(validator.apply(instance).basic()).unwrap();
    assert_eq!(&output, expected_output);
}

/// These tests are separated from the rest of the basic output tests for convenience, there's
/// nothing different about them but they are all tests of the additionalProperties keyword, which
/// is complicated by the fact that there are eight different implementations based on the
/// interaction between the properties, patternProperties, and additionalProperties keywords.
/// Specifically there are these implementations:
///
/// - AdditionalPropertiesValidator
/// - AdditionalPropertiesFalseValidator
/// - AdditionalPropertiesNotEmptyFalseValidator
/// - AdditionalPropertiesNotEmptyValidator
/// - AdditionalPropertiesWithPatternsValidator
/// - AdditionalPropertiesWithPatternsFalseValidator
/// - AdditionalPropertiesWithPatternsNotEmptyValidator
/// - AdditionalPropertiesWithPatternsNotEmptyFalseValidator
///
/// For each of these we need two test cases, one for errors and one for annotations
#[test_case{
    &json!({
        "additionalProperties": {"type": "number" }
    }),
    &json!({
        "name": "somename",
        "otherprop": "one"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties/type",
                "instanceLocation": "/name",
                "error": "\"somename\" is not of type \"number\""
            },
            {
                "keywordLocation": "/additionalProperties/type",
                "instanceLocation": "/otherprop",
                "error": "\"one\" is not of type \"number\""
            },
        ]
    }); "invalid AdditionalPropertiesValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": {"type": "number", "some": "annotation" }
    }),
    &json!({
        "name": 1,
        "otherprop": 2
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "annotations": ["name", "otherprop"]
            },
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "/name",
                "annotations": {
                    "some": "annotation"
                }
            },
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "/otherprop",
                "annotations": {
                    "some": "annotation"
                }
            },
        ]
    }); "valid AdditionalPropertiesValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": false
    }),
    &json!({
        "name": "somename",
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "error": "False schema does not allow \"somename\""
            },
        ]
    }); "invalid AdditionalPropertiesFalseValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": false
    }),
    &json!({}),
    &json!({
        "valid": true,
        "annotations": []
    }); "valid AdditionalPropertiesFalseValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": false,
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        }
    }),
    &json!({
        "name": "somename",
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/properties/name",
                "instanceLocation": "/name",
                "annotations": {"prop": "annotation"}
            }
        ]
    }); "valid AdditionalPropertiesNotEmptyFalseValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": false,
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        }
    }),
    &json!({
        "name": "somename",
        "other": "prop"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "error": "Additional properties are not allowed ('other' was unexpected)"
            }
        ]
    }); "invalid AdditionalPropertiesNotEmptyFalseValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": {"type": "integer", "other": "annotation"},
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        }
    }),
    &json!({
        "name": "somename",
        "otherprop": 1
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "annotations": ["otherprop"]
            },
            {
                "keywordLocation": "/properties/name",
                "instanceLocation": "/name",
                "annotations": {"prop": "annotation"}
            },
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "/otherprop",
                "annotations": {"other": "annotation"}
            }
        ]
    }); "valid AdditionalPropertiesNotEmptyValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": {"type": "integer", "other": "annotation"},
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        }
    }),
    &json!({
        "name": "somename",
        "otherprop": "one"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties/type",
                "instanceLocation": "/otherprop",
                "error": "\"one\" is not of type \"integer\""
            },
        ]
    }); "invalid AdditionalPropertiesNotEmptyValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": {"type": "string", "other": "annotation"},
        "patternProperties": {
            "^x-": {"type": "integer", "minimum": 5, "patternio": "annotation"},
        }
    }),
    &json!({
        "otherprop": "one",
        "x-foo": 7
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "annotations": ["otherprop"]
            },
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "/otherprop",
                "annotations": {"other": "annotation"}
            },
            {
                "keywordLocation": "/patternProperties/^x-",
                "instanceLocation": "/x-foo",
                "annotations": {"patternio": "annotation"}
            },
            {
                "keywordLocation": "/patternProperties",
                "instanceLocation": "",
                "annotations": ["x-foo"]
            }
        ]
    }); "valid AdditionalPropertiesWithPatternsValidator"
}]
#[test_case{
    &json!({
        "additionalProperties": {"type": "string" },
        "patternProperties": {
            "^x-": {"type": "integer", "minimum": 5 },
        }
    }),
    &json!({
        "otherprop":1,
        "x-foo": 3
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties/type",
                "instanceLocation": "/otherprop",
                "error": "1 is not of type \"string\""
            },
            {
                "keywordLocation": "/patternProperties/^x-/minimum",
                "instanceLocation": "/x-foo",
                "error": "3 is less than the minimum of 5"
            },
        ]
    }); "invalid AdditionalPropertiesWithPatternsValidator"
}]
#[test_case{
    &json!({
        "properties": {
            "name": {"type": "string"}
        },
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string" }
        },
        "additionalProperties": {"type": "number" }
    }),
    &json!({
        "name": "somename",
        "otherprop": "one"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties/type",
                "instanceLocation": "/otherprop",
                "error": "\"one\" is not of type \"number\""
            },
        ]
    }); "invalid AdditionalPropertiesWithPatternsNotEmptyValidator"
}]
#[test_case{
    &json!({
        "properties": {
            "name": {"type": "string"}
        },
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string" }
        },
        "additionalProperties": {"type": "number" }
    }),
    &json!({
        "name": "somename",
        "otherprop": 1
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "annotations": ["otherprop"]
            }
        ]
    }); "valid AdditionalPropertiesWithPatternsNotEmptyValidator"
}]
#[test_case{
    &json!({
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        },
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string" }
        },
        "additionalProperties": false
    }),
    &json!({
        "name": "somename",
        "stringProp1": "one"
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/properties/name",
                "instanceLocation": "/name",
                "annotations": {
                    "prop": "annotation"
                }
            }
        ]
    }); "valid AdditionalPropertiesWithPatternsNotEmptyFalseValidator"
}]
#[test_case{
    &json!({
        "properties": {
            "name": {"type": "string", "prop": "annotation"}
        },
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string" }
        },
        "additionalProperties": false
    }),
    &json!({
        "name": "somename",
        "stringProp1": "one",
        "otherprop": "something"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "error": "Additional properties are not allowed ('otherprop' was unexpected)"
            }
        ]
    }); "invalid AdditionalPropertiesWithPatternsNotEmptyFalseValidator"
}]
#[test_case{
    &json!({
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string", "some": "annotation"}
        },
        "additionalProperties": false
    }),
    &json!({
        "stringProp1": "one",
    }),
    &json!({
        "valid": true,
        "annotations": [
            {
                "keywordLocation": "/patternProperties/stringProp(\\d+)",
                "instanceLocation": "/stringProp1",
                "annotations": {
                    "some": "annotation"
                }
            },
            {
                "keywordLocation": "/patternProperties",
                "instanceLocation": "",
                "annotations": ["stringProp1"]
            },
        ]
    }); "valid AdditionalPropertiesWithPatternsFalseValidator"
}]
#[test_case{
    &json!({
        "patternProperties": {
            "stringProp(\\d+)": {"type": "string" }
        },
        "additionalProperties": false
    }),
    &json!({
        "stringProp1": "one",
        "otherprop": "something"
    }),
    &json!({
        "valid": false,
        "errors": [
            {
                "keywordLocation": "/additionalProperties",
                "instanceLocation": "",
                "error": "Additional properties are not allowed ('otherprop' was unexpected)"
            }
        ]
    }); "invalid AdditionalPropertiesWithPatternsFalseValidator"
}]
fn test_additional_properties_basic_output(
    schema: &serde_json::Value,
    instance: &serde_json::Value,
    expected: &serde_json::Value,
) {
    let validator = jsonschema::validator_for(schema).unwrap();
    let output = serde_json::to_value(validator.apply(instance).basic()).unwrap();
    if &output != expected {
        let expected_str = serde_json::to_string_pretty(expected).unwrap();
        let actual_str = serde_json::to_string_pretty(&output).unwrap();
        panic!("\nExpected:\n{expected_str}\n\nGot:\n{actual_str}\n");
    }
}
