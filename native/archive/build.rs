use std::{env, path::PathBuf, process::Command};

fn main() {
    let root = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let target = env::var("TARGET").unwrap();
    let compiler = cc::Build::new().get_compiler();
    let mut build = Command::new(env::var("PYTHON").unwrap_or_else(|_| "python3".into()));
    build
        .arg(root.join("scripts/build_native.py"))
        .arg("--out")
        .arg(out.join("native"))
        .arg("--cc")
        .arg(compiler.path());
    for (key, value) in compiler.env() {
        build.env(key, value);
    }
    assert!(
        build
            .status()
            .expect("Python 3.12+, CMake and Ninja are required for source builds")
            .success(),
        "native dependency build failed"
    );
    let lib = out.join("native/install/lib");
    println!("cargo:rustc-link-search=native={}", lib.display());
    for name in if target.contains("windows") {
        vec![
            "archive_static",
            "xml2",
            "zstd_static",
            "lz4",
            "lzma",
            "bz2",
            "zlibstatic",
        ]
    } else {
        vec!["archive", "xml2", "zstd", "lz4", "lzma", "bz2", "z"]
    } {
        println!("cargo:rustc-link-lib=static={name}");
    }
    if target.contains("apple") {
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        println!("cargo:rustc-link-lib=framework=Security");
    } else if target.contains("windows") {
        for name in [
            "bcrypt", "crypt32", "ws2_32", "advapi32", "user32", "xmllite", "ole32", "uuid",
        ] {
            println!("cargo:rustc-link-lib={name}");
        }
    }
    let mut builder = bindgen::Builder::default()
        .header(root.join("vendor/libarchive/archive.h").to_string_lossy())
        .header(
            root.join("vendor/libarchive/archive_entry.h")
                .to_string_lossy(),
        )
        .clang_arg("-DLIBARCHIVE_STATIC")
        .allowlist_function("archive_.*")
        .allowlist_var("ARCHIVE_.*|AE_.*")
        .allowlist_type("ARCHIVE_BIND_.*")
        .clang_arg(format!("-I{}", root.join("vendor/libarchive").display()))
        .header_contents("archive_modes.h", "#include \"archive.h\"\n#include \"archive_entry.h\"\ntypedef struct stat ARCHIVE_BIND_STAT;\ntypedef __LA_DEV_T ARCHIVE_BIND_DEV_T;\ntypedef __LA_INO_T ARCHIVE_BIND_INO_T;\ntypedef __LA_MODE_T ARCHIVE_BIND_MODE_T;\nenum { ARCHIVE_BIND_AE_IFMT=AE_IFMT, ARCHIVE_BIND_AE_IFBLK=AE_IFBLK, ARCHIVE_BIND_AE_IFCHR=AE_IFCHR, ARCHIVE_BIND_AE_IFDIR=AE_IFDIR, ARCHIVE_BIND_AE_IFIFO=AE_IFIFO, ARCHIVE_BIND_AE_IFLNK=AE_IFLNK, ARCHIVE_BIND_AE_IFREG=AE_IFREG, ARCHIVE_BIND_AE_IFSOCK=AE_IFSOCK };")
        .layout_tests(false)
        .derive_debug(false)
        .generate_comments(false);
    if target.contains("windows") {
        // Use the same CRT headers and include search path as cl.exe.
        for (key, value) in compiler.env() {
            if key.to_string_lossy().eq_ignore_ascii_case("INCLUDE") {
                for dir in value.to_string_lossy().split(';').filter(|s| !s.is_empty()) {
                    builder = builder.clang_arg(format!("-I{dir}"));
                }
            }
        }
        builder = builder.clang_arg(format!("--target={target}"));
    }
    let bindings = builder
        .generate()
        .expect("libclang and platform C headers are required for source builds");
    bindings.write_to_file(out.join("ffi.rs")).unwrap();
    for path in [
        "scripts/build_native.py",
        "native/dependencies.json",
        "vendor/libarchive/archive.h",
        "vendor/libarchive/archive_entry.h",
    ] {
        println!("cargo:rerun-if-changed={}", root.join(path).display());
    }
    println!("cargo:rerun-if-env-changed=ARCHIVE_NATIVE_CACHE");
    println!(
        "cargo:metadata=licenses={}",
        out.join("native/install/share/archive/licenses").display()
    );
}
