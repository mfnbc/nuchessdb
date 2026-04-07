use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};

pub struct IsLegal;

impl PluginCommand for IsLegal {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb is-legal"
    }

    fn description(&self) -> &str {
        "Return true if a SAN or UCI move is legal in the given FEN."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .required("move", SyntaxShape::String, "SAN or UCI move to test")
            .input_output_types(vec![(Type::String, Type::Bool)])
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
        let move_str: String = call.req(0)?;

        let is_legal = crate::core::is_legal(&fen_str, &move_str, call.head)?;

        Ok(PipelineData::Value(Value::bool(is_legal, call.head), None))
    }
}
