use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{
    Category, LabeledError, PipelineData, Record, Signature, SyntaxShape, Type, Value,
};

pub struct CritterEval;

impl PluginCommand for CritterEval {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb critter-eval"
    }

    fn description(&self) -> &str {
        "Evaluate a chess position (FEN from pipeline) and return a full critter-eval record."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::Record(vec![].into()))])
            .named(
                "engine-score",
                SyntaxShape::Int,
                "Optional engine centipawn score to compare against",
                Some('e'),
            )
            .category(Category::Custom("chess".into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let fen_str = input.into_value(call.head)?.as_str()?.to_string();
        let span = call.head;

        let engine_score: Option<i64> = call.get_flag("engine-score")?;

        let record = crate::eval::analyze_fen_with_engine_score(&fen_str, engine_score)
            .map_err(|e| LabeledError::new(e.to_string()).with_label("eval error", span))?;

        // Serialize the full record to a Nu Value via serde_json -> Value::record
        let json_val = serde_json::to_value(&record).map_err(|e| {
            LabeledError::new(e.to_string()).with_label("serialization error", span)
        })?;

        Ok(PipelineData::Value(json_to_nu_value(json_val, span), None))
    }
}

/// Recursively convert a serde_json::Value into a nu_protocol::Value.
fn json_to_nu_value(val: serde_json::Value, span: nu_protocol::Span) -> Value {
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
