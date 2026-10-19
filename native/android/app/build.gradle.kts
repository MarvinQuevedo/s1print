plugins { id("com.android.application") }
android {
    namespace = "inc.imx.s1print"
    compileSdk = 36
    defaultConfig {
        applicationId = "inc.imx.s1print"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.4.0-native-preview"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    ndkVersion = "26.3.11579264"
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildTypes { getByName("release") { isMinifyEnabled = false } }
}
val buildRust by tasks.registering(Exec::class) {
    workingDir(rootProject.projectDir.resolve("../.."))
    commandLine("python3", "scripts/build-android-rust.py")
    inputs.dir(rootProject.projectDir.resolve("../../rust/s1-core/src"))
    inputs.dir(rootProject.projectDir.resolve("../../rust/s1-native/src"))
    inputs.file(rootProject.projectDir.resolve("../../rust/Cargo.lock"))
    inputs.file(rootProject.projectDir.resolve("../../rust/Cargo.toml"))
    inputs.file(rootProject.projectDir.resolve("../../rust/s1-native/Cargo.toml"))
    inputs.file(rootProject.projectDir.resolve("../../rust/s1-core/Cargo.toml"))
    inputs.file(rootProject.projectDir.resolve("../../scripts/build-android-rust.py"))
    outputs.dir("src/main/jniLibs")
}
tasks.named("preBuild") { dependsOn(buildRust) }

dependencies {
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
