use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};

pub struct SanToUci;

impl PluginCommand for SanToUci {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb san-to-uci"
    }

    fn description(&self) -> &str {
        "Convert a SAN move to UCI notation given a FEN."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("san", SyntaxShape::String, "SAN move to convert")
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
        let san_str: String = call.req(0)?;

        let uci = crate::core::san_to_uci(&fen_str, &san_str, call.head)?;
        Ok(PipelineData::Value(Value::string(uci, call.head), None))
    }
}
