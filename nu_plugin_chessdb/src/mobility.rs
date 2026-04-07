use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct Mobility;

impl PluginCommand for Mobility {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb mobility"
    }

    fn description(&self) -> &str {
        "Return legal move count and SAN mobility for the side to move."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::Record(vec![].into()))])
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
        let summary = crate::core::mobility_summary(&fen_str, call.head)?;

        let mut rec = Record::new();
        rec.push(
            "side_to_move",
            Value::string(summary.side_to_move, call.head),
        );
        rec.push(
            "legal_move_count",
            Value::int(summary.legal_move_count, call.head),
        );
        rec.push(
            "mobility_san",
            Value::list(
                summary
                    .mobility_san
                    .into_iter()
                    .map(|san| Value::string(san, call.head))
                    .collect(),
                call.head,
            ),
        );

        Ok(PipelineData::Value(Value::record(rec, call.head), None))
    }
}
