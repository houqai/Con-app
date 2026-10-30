fn main() {
    println!("cargo:rerun-if-env-changed=CON_LOGIN_LIBRARY_DIRS");
    println!("cargo:rerun-if-env-changed=CON_LOGIN_RESOURCES");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if let Ok(folders) = std::env::var("CON_LOGIN_LIBRARY_DIRS") {
        for folder in folders.split(';').filter(|folder| !folder.is_empty()) {
            println!("cargo:rustc-link-search=native={folder}");
        }
    }
    if let Ok(resources) = std::env::var("CON_LOGIN_RESOURCES") {
        if !resources.is_empty() {
            println!("cargo:rerun-if-changed={resources}");
            println!("cargo:rustc-link-arg-bins={resources}");
        }
    }
}
