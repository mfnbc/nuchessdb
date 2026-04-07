use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct LegalMoves;

impl PluginCommand for LegalMoves {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb legal-moves"
    }

    fn description(&self) -> &str {
        "List all legal moves from a FEN as a table with san and uci columns."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(
                Type::String,
                Type::List(Box::new(Type::Record(vec![].into()))),
            )])
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
        let rows = crate::core::legal_moves(&fen_str, span)?;

        let rows: Vec<Value> = rows
            .into_iter()
            .map(|row| {
                let mut record = Record::new();
                record.push("san", Value::string(row.san, span));
                record.push("uci", Value::string(row.uci, span));
                Value::record(record, span)
            })
            .collect();

        Ok(PipelineData::Value(Value::list(rows, span), None))
    }
}
