#!/usr/bin/env python3
"""Build the Rust C ABI as a static XCFramework for iOS devices and simulators."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/ios-rust'
FRAMEWORK = ROOT / 'native/ios/Frameworks/S1Native.xcframework'

def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)

OUT.mkdir(parents=True, exist_ok=True)
headers = OUT / 'include'
headers.mkdir(exist_ok=True)
shutil.copyfile(ROOT / 'rust/s1-native/s1_native.h', headers / 's1_native.h')
for target in ['aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios']:
    run('cargo', 'build', '--manifest-path', 'rust/Cargo.toml', '--locked', '--release', '-p', 's1-native', '--target', target)
simulator = OUT / 'libS1Native-simulator.a'
run('lipo', '-create', str(ROOT / 'rust/target/aarch64-apple-ios-sim/release/libs1_native.a'),
    str(ROOT / 'rust/target/x86_64-apple-ios/release/libs1_native.a'), '-output', str(simulator))
if FRAMEWORK.exists():
    shutil.rmtree(FRAMEWORK)
run('xcodebuild', '-create-xcframework', '-library', str(ROOT / 'rust/target/aarch64-apple-ios/release/libs1_native.a'),
    '-headers', str(headers), '-library', str(simulator), '-headers', str(headers), '-output', str(FRAMEWORK))
