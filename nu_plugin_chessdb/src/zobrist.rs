use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};

pub struct Zobrist;

impl PluginCommand for Zobrist {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb zobrist"
    }

    fn description(&self) -> &str {
        "Compute Zobrist hash for a FEN."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .switch("int", "Output as integer instead of hex", Some('i'))
            .input_output_types(vec![(Type::String, Type::String)])
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &Self::Plugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> Result<PipelineData, LabeledError> {
        let fen_str = input.into_value(call.head)?.as_str()?.to_string();
        let as_int = call.has_flag("int")?;

        let result = crate::core::zobrist(&fen_str, as_int, call.head)?;

        Ok(PipelineData::Value(Value::string(result, call.head), None))
    }
}
