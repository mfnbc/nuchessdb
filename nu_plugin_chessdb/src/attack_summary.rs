use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct AttackSummary;

impl PluginCommand for AttackSummary {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb attack-summary"
    }

    fn description(&self) -> &str {
        "Return attacked squares and attack counts for both sides."
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
        let summary = crate::core::attack_summary(&fen_str, call.head)?;

        let mut rec = Record::new();
        rec.push(
            "attacked_by_white",
            Value::list(
                summary
                    .attacked_by_white
                    .into_iter()
                    .map(|sq| Value::string(sq, call.head))
                    .collect(),
                call.head,
            ),
        );
        rec.push(
            "attacked_by_black",
            Value::list(
                summary
                    .attacked_by_black
                    .into_iter()
                    .map(|sq| Value::string(sq, call.head))
                    .collect(),
                call.head,
            ),
        );
        rec.push(
            "white_attack_count",
            Value::int(summary.white_attack_count, call.head),
        );
        rec.push(
            "black_attack_count",
            Value::int(summary.black_attack_count, call.head),
        );

        Ok(PipelineData::Value(Value::record(rec, call.head), None))
    }
}
