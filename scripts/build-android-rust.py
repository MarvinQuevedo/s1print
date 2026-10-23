#!/usr/bin/env python3
"""Build and package the shared Rust library using the installed Android NDK."""
import os
import pathlib
import platform
import shutil
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
sdk = pathlib.Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", str(pathlib.Path.home() / "Library/Android/sdk"))))
ndk = pathlib.Path(os.environ.get("ANDROID_NDK_HOME", str(sdk / "ndk/26.3.11579264")))
host = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
bin_dir = ndk / "toolchains/llvm/prebuilt" / host / "bin"
if not bin_dir.exists():
    raise SystemExit(f"Android NDK not found at {ndk}; set ANDROID_NDK_HOME")
for abi, target, cc in [("arm64-v8a", "aarch64-linux-android", "aarch64-linux-android26-clang"),
                        ("x86_64", "x86_64-linux-android", "x86_64-linux-android26-clang")]:
    env = os.environ.copy()
    prefix = f"CARGO_TARGET_{target.upper().replace('-', '_')}"
    env[f"{prefix}_LINKER"] = str(bin_dir / cc)
    env[f"{prefix}_RUSTFLAGS"] = env.get(f"{prefix}_RUSTFLAGS", "") + " -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
    subprocess.run(["cargo", "build", "--locked", "--release", "--manifest-path", str(root / "rust/Cargo.toml"),
                    "-p", "s1-native", "--target", target], env=env, check=True)
    dest = root / "native/android/app/src/main/jniLibs" / abi
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "rust/target" / target / "release/libs1_native.so", dest)
