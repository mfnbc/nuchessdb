use nu_protocol::{Record, Value};

/// Recursively convert a `serde_json::Value` into a `nu_protocol::Value`.
pub fn json_to_nu_value(val: serde_json::Value, span: nu_protocol::Span) -> Value {
    match val {
        serde_json::Value::Null => Value::nothing(span),
        serde_json::Value::Bool(b) => Value::bool(b, span),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::int(i, span)
            } else if let Some(f) = n.as_f64() {
                Value::float(f, span)
            } else {
                Value::string(n.to_string(), span)
            }
        }
        serde_json::Value::String(s) => Value::string(s, span),
        serde_json::Value::Array(arr) => {
            let items: Vec<Value> = arr.into_iter().map(|v| json_to_nu_value(v, span)).collect();
            Value::list(items, span)
        }
        serde_json::Value::Object(obj) => {
            let mut rec = Record::new();
            for (k, v) in obj {
                rec.push(k, json_to_nu_value(v, span));
            }
            Value::record(rec, span)
        }
    }
}
