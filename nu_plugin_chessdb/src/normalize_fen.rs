use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};

pub struct NormalizeFen;

impl PluginCommand for NormalizeFen {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb normalize-fen"
    }

    fn description(&self) -> &str {
        "Parse a FEN and return its normalized canonical form."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::String)])
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
        let normalized = crate::core::normalize_fen(&fen_str, call.head)?;

        Ok(PipelineData::Value(
            Value::string(normalized, call.head),
            None,
        ))
    }
}
