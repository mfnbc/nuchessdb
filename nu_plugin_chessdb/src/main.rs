fn main() {
    nu_plugin::serve_plugin(
        &nu_plugin_chessdb::ChessdbPlugin::new(),
        nu_plugin::MsgPackSerializer,
    );
}
