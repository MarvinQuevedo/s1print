param([string]$Output = "", [switch]$Installer)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (!$Output) { $Output = Join-Path $root "build/windows" }
$Output = [System.IO.Path]::GetFullPath($Output)
Push-Location $root
try {
    rustup target add x86_64-pc-windows-msvc
    if ($LASTEXITCODE) { throw "Cannot install Windows Rust target" }
    cargo build --manifest-path rust/Cargo.toml --locked --release -p s1-native --target x86_64-pc-windows-msvc
    if ($LASTEXITCODE) { throw "Rust build failed" }
    dotnet publish native/windows/S1Print/S1Print.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o "$Output/app"
    if ($LASTEXITCODE) { throw "Windows application build failed" }
    Copy-Item rust/target/x86_64-pc-windows-msvc/release/s1_native.dll "$Output/app/s1_native.dll" -Force
    Copy-Item docs/NATIVE_PLATFORMS.md "$Output/app/SETUP.md" -Force
    Compress-Archive -Path "$Output/app/*" -DestinationPath "$Output/S1Print-Windows-x64.zip" -Force
    if ($Installer) {
        $iscc = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe"
        if (!(Test-Path $iscc)) { throw "Install Inno Setup 6 to build the installer" }
        & $iscc "/DAppSource=$Output/app" "/DOutputDirectory=$Output" native/windows/installer.iss
        if ($LASTEXITCODE) { throw "Installer build failed" }
    }
    Write-Output "Windows package: $Output/S1Print-Windows-x64.zip"
} finally { Pop-Location }
