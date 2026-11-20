fn main() {
    println!("cargo:rerun-if-changed=Cargo.toml");
    let manifest: toml::Table = std::fs::read_to_string("Cargo.toml")
        .expect("read Cargo.toml")
        .parse()
        .expect("parse Cargo.toml");
    let version = manifest["dependencies"]["wasmtime"]["version"]
        .as_str()
        .and_then(|version| version.strip_prefix('='))
        .expect("wasmtime must be pinned to an exact version");
    println!("cargo:rustc-env=KETTLECORN_WASMTIME_VERSION={version}");
}
