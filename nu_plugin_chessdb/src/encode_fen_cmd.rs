use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, Type, Value};

pub struct EncodeFen;

impl PluginCommand for EncodeFen {
    type Plugin = crate::ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb encode-fen"
    }

    fn description(&self) -> &str {
        "Encode a FEN string (from pipeline) into a 1024-element f32 position vector."
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::List(Box::new(Type::Float)))])
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

        let parsed = shakmaty::fen::Fen::from_ascii(fen_str.as_bytes())
            .map_err(|e| LabeledError::new(e.to_string()).with_label("FEN parse error", span))?;
        let chess: shakmaty::Chess = parsed
            .into_position(shakmaty::CastlingMode::Standard)
            .map_err(|e| LabeledError::new(e.to_string()).with_label("FEN position error", span))?;

        let features = crate::position_encoder::encode_position(&chess);
        let items: Vec<Value> = features
            .into_iter()
            .map(|f| Value::float(f64::from(f), span))
            .collect();

        Ok(PipelineData::Value(Value::list(items, span), None))
    }
}
