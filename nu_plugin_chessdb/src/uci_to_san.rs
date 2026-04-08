use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};

pub struct UciToSan;

impl PluginCommand for UciToSan {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb uci-to-san"
    }

    fn description(&self) -> &str {
        "Convert a UCI move to SAN notation given a FEN."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("uci", SyntaxShape::String, "UCI move to convert")
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
        let uci_str: String = call.req(0)?;

        let san = crate::core::uci_to_san(&fen_str, &uci_str, call.head)?;
        Ok(PipelineData::Value(Value::string(san, call.head), None))
    }
}
