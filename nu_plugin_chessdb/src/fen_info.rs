use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Record, Signature, Type, Value};

pub struct FenInfo;

impl PluginCommand for FenInfo {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb fen-info"
    }

    fn description(&self) -> &str {
        "Parse a FEN and return a record with position metadata."
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
        let span = call.head;
        let info = crate::core::fen_info(&fen_str, span)?;

        let mut rec = Record::new();
        rec.push("fen", Value::string(info.fen, span));
        rec.push("turn", Value::string(info.turn, span));
        rec.push("castling", Value::string(info.castling, span));
        rec.push("ep_square", Value::string(info.ep_square, span));
        rec.push("halfmoves", Value::int(info.halfmoves, span));
        rec.push("fullmoves", Value::int(info.fullmoves, span));
        rec.push("material_white", Value::int(info.material_white, span));
        rec.push("material_black", Value::int(info.material_black, span));
        rec.push("material_diff", Value::int(info.material_diff, span));
        rec.push("is_check", Value::bool(info.is_check, span));
        rec.push("is_checkmate", Value::bool(info.is_checkmate, span));
        rec.push("is_stalemate", Value::bool(info.is_stalemate, span));
        rec.push(
            "is_insufficient_material",
            Value::bool(info.is_insufficient_material, span),
        );
        rec.push("legal_move_count", Value::int(info.legal_move_count, span));

        Ok(PipelineData::Value(Value::record(rec, span), None))
    }
}
