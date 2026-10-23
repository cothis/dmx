const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("dmx-agent {VERSION}");
        return;
    }
    eprintln!("dmx-agent {VERSION}: nothing to do yet");
}
