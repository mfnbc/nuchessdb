use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};

pub struct ApplySan;

impl PluginCommand for ApplySan {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb apply-san"
    }

    fn description(&self) -> &str {
        "Apply a SAN move to a FEN and return the next FEN."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("san", SyntaxShape::String, "SAN move to apply")
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
        let san_str: String = call.req(0)?;

        let result = crate::core::apply_san(&fen_str, &san_str, call.head)?;

        Ok(PipelineData::Value(Value::string(result, call.head), None))
    }
}
