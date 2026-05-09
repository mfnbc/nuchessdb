use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};

pub struct Zobrist;

impl PluginCommand for Zobrist {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb zobrist"
    }

    fn description(&self) -> &str {
        "Compute Zobrist hash for a FEN or list of FENs."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .switch("int", "Output as integer instead of hex", Some('i'))
            .input_output_types(vec![
                (Type::String, Type::String),
                (
                    Type::List(Box::new(Type::String)),
                    Type::List(Box::new(Type::String)),
                ),
            ])
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let as_int = call.has_flag("int")?;
        let input_value = input.into_value(call.head)?;

        match input_value {
            Value::String { val, .. } => {
                // Single FEN string
                let result = crate::core::zobrist(&val, as_int, call.head)?;
                Ok(PipelineData::Value(Value::string(result, call.head), None))
            }
            Value::List { vals, .. } => {
                // List of FEN strings
                let mut results = Vec::with_capacity(vals.len());
                for val in vals {
                    let fen_str = val.as_str()?;
                    let hash = crate::core::zobrist(fen_str, as_int, call.head)?;
                    results.push(Value::string(hash, call.head));
                }
                Ok(PipelineData::Value(Value::list(results, call.head), None))
            }
            _ => Err(LabeledError::new("Expected string or list of strings")
                .with_label("invalid input type", call.head)),
        }
    }
}
