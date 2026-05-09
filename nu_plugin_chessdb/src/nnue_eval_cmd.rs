/// `chessdb nnue-eval` — evaluate a FEN using a chess-vector-engine NNUE weight file.
///
/// The weight file is a JSON array of tuples: `Vec<(String, Vec<usize>, Vec<f32>)>`.
/// Each tuple is `(layer_name, shape, flat_data)`.
///
/// Architecture (default config):
///   input (768 piece-position features)
///   → feature_transformer (768 → hidden_size) + bias → ClippedReLU
///   → N hidden layers (hidden_size → hidden_size) + bias → ClippedReLU
///   → output layer (hidden_size → 1) + bias
///   → multiply by 600.0 to get centipawns
///
/// This is a hand-rolled forward pass with no external ML dependencies.
use anyhow::{Context, Result};
use nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand};
use nu_protocol::{Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value};
use serde::Deserialize;
use std::collections::HashMap;

use crate::position_encoder::encode_position;
use crate::ChessdbPlugin;
use shakmaty::{fen::Fen, CastlingMode, Chess};

pub struct NnueEval;

#[derive(Debug, Deserialize)]
struct NnueConfig {
    pub feature_size: usize,
    pub hidden_size: usize,
    pub num_hidden_layers: usize,
    pub activation: String,
    // remaining fields are not needed for inference
}

impl Default for NnueConfig {
    fn default() -> Self {
        Self {
            feature_size: 768,
            hidden_size: 256,
            num_hidden_layers: 2,
            activation: "ClippedReLU".to_string(),
        }
    }
}

/// A layer with weight matrix (out × in) and bias vector (out).
struct Layer {
    weight: Vec<f32>, // row-major, shape [out_size × in_size]
    bias: Vec<f32>,   // shape [out_size]
    out_size: usize,
    in_size: usize,
}

impl Layer {
    fn forward(&self, input: &[f32]) -> Vec<f32> {
        assert_eq!(input.len(), self.in_size, "layer input size mismatch");
        let mut output = vec![0.0f32; self.out_size];
        // Weight stored as [in_size × out_size] (column-major from PyTorch/candle convention).
        // output[j] = bias[j] + sum_i(input[i] * weight[i * out_size + j])
        for i in 0..self.in_size {
            let xi = input[i];
            if xi == 0.0 {
                continue;
            }
            for j in 0..self.out_size {
                output[j] += xi * self.weight[i * self.out_size + j];
            }
        }
        for j in 0..self.out_size {
            output[j] += self.bias[j];
        }
        output
    }
}

fn clipped_relu(v: &[f32]) -> Vec<f32> {
    v.iter().map(|&x| x.max(0.0).min(1.0)).collect()
}

fn apply_activation(v: &[f32], activation: &str) -> Vec<f32> {
    match activation {
        "ClippedReLU" | "clipped_relu" => clipped_relu(v),
        "ReLU" | "relu" => v.iter().map(|&x| x.max(0.0)).collect(),
        _ => clipped_relu(v), // default to ClippedReLU
    }
}

/// Load weight map from the JSON file.
/// Format: `[[name, [dim0, dim1, ...], [f0, f1, ...]], ...]`
fn load_weights(path: &str) -> Result<HashMap<String, (Vec<usize>, Vec<f32>)>> {
    let content = std::fs::read_to_string(path).context("reading weights file")?;
    let raw: Vec<(String, Vec<usize>, Vec<f32>)> =
        serde_json::from_str(&content).context("parsing weights JSON")?;
    let mut map = HashMap::new();
    for (name, shape, data) in raw {
        map.insert(name, (shape, data));
    }
    Ok(map)
}

/// Load optional config file (same base name, .config extension).
fn load_config(weights_path: &str) -> NnueConfig {
    let config_path = if weights_path.ends_with(".weights") {
        weights_path.replace(".weights", ".config")
    } else {
        format!("{}.config", weights_path)
    };
    std::fs::read_to_string(&config_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn run_nnue(fen: &str, weights_path: &str) -> Result<serde_json::Value> {
    // Parse FEN
    let parsed = Fen::from_ascii(fen.as_bytes()).context("invalid FEN")?;
    let chess: Chess = parsed
        .into_position(CastlingMode::Standard)
        .context("FEN to position")?;

    // Encode position (1024-element vector; we use first 768)
    let features_full = encode_position(&chess);
    let config = load_config(weights_path);
    let input_size = config.feature_size.min(features_full.len());
    let input = &features_full[..input_size];

    // Load weights
    let weights = load_weights(weights_path)?;

    let get_layer = |name_w: &str, name_b: &str, in_size: usize| -> Result<Layer> {
        let (_shape_w, data_w) = weights
            .get(name_w)
            .with_context(|| format!("missing layer {}", name_w))?;
        let (_shape_b, data_b) = weights
            .get(name_b)
            .with_context(|| format!("missing layer {}", name_b))?;
        // Derive out_size from data length and known in_size.
        // All weight tensors are stored as flat [in_size × out_size] data.
        anyhow::ensure!(
            in_size > 0 && data_w.len() % in_size == 0,
            "weight data length {} not divisible by in_size {} for {}",
            data_w.len(),
            in_size,
            name_w
        );
        let out_size = data_w.len() / in_size;
        anyhow::ensure!(
            data_b.len() == out_size,
            "bias size mismatch for {}: expected {} got {}",
            name_b,
            out_size,
            data_b.len()
        );
        Ok(Layer {
            weight: data_w.clone(),
            bias: data_b.clone(),
            out_size,
            in_size,
        })
    };

    // Feature transformer: input_size → hidden_size
    let ft = get_layer(
        "feature_transformer.weights",
        "feature_transformer.biases",
        input_size,
    )?;
    let mut hidden = apply_activation(&ft.forward(input), &config.activation);

    // Hidden layers
    for i in 0..config.num_hidden_layers {
        let w_name = format!("hidden_layer_{}.weight", i);
        let b_name = format!("hidden_layer_{}.bias", i);
        if weights.contains_key(&w_name) {
            let layer = get_layer(&w_name, &b_name, hidden.len())?;
            hidden = apply_activation(&layer.forward(&hidden), &config.activation);
        }
    }

    // Output layer
    let out_layer = get_layer("output_layer.weight", "output_layer.bias", hidden.len())?;
    let raw_output = out_layer.forward(&hidden);
    let score_raw = raw_output[0];
    let score_cp = (score_raw * 600.0) as i64;

    Ok(serde_json::json!({
        "score_cp": score_cp,
        "score_pawns": score_raw * 6.0,
        "weights_path": weights_path,
        "config": {
            "feature_size": config.feature_size,
            "hidden_size": config.hidden_size,
            "num_hidden_layers": config.num_hidden_layers,
            "activation": config.activation,
        }
    }))
}

impl PluginCommand for NnueEval {
    type Plugin = ChessdbPlugin;

    fn name(&self) -> &str {
        "chessdb nnue-eval"
    }

    fn description(&self) -> &str {
        "Evaluate a FEN position using a chess-vector-engine NNUE weight file"
    }

    fn signature(&self) -> Signature {
        Signature::build(self.name())
            .input_output_types(vec![(Type::String, Type::record())])
            .required_named(
                "weights",
                SyntaxShape::String,
                "path to the .weights file (JSON format from chess-vector-engine)",
                Some('w'),
            )
            .category(Category::Custom(crate::PLUGIN_CATEGORY.into()))
    }

    fn run(
        &self,
        _plugin: &ChessdbPlugin,
        _engine: &EngineInterface,
        call: &EvaluatedCall,
        input: PipelineData,
    ) -> std::result::Result<PipelineData, LabeledError> {
        let weights_path: String = call
            .get_flag("weights")
            .map_err(|e| LabeledError::new(e.to_string()))?
            .ok_or_else(|| LabeledError::new("--weights is required"))?;

        let fen = match input {
            PipelineData::Value(Value::String { val, .. }, _) => val,
            PipelineData::Value(v, _) => v
                .coerce_string()
                .map_err(|e| LabeledError::new(format!("expected string input (FEN): {}", e)))?,
            _ => {
                return Err(LabeledError::new("expected FEN string as pipeline input"));
            }
        };

        let result = run_nnue(fen.trim(), &weights_path)
            .map_err(|e| LabeledError::new(format!("nnue-eval error: {}", e)))?;

        // Convert serde_json::Value to nu Value
        let span = call.head;
        let nu_val = crate::utils::json_to_nu_value(result, span);
        Ok(PipelineData::Value(nu_val, None))
    }
}
