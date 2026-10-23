import java.util.Properties

plugins { id("com.android.application") }

// Upload key for Google Play, kept outside the repository. Point
// S1PRINT_UPLOAD_PROPERTIES (or ~/.android/s1print-upload.properties) at a file
// with storeFile, storePassword, keyAlias and keyPassword.
val uploadProps = Properties().apply {
    val path = System.getenv("S1PRINT_UPLOAD_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.android/s1print-upload.properties"
    val f = file(path)
    if (f.exists()) f.inputStream().use { load(it) }
}
android {
    namespace = "inc.imx.s1print"
    compileSdk = 36
    defaultConfig {
        // Same id as the iOS and Mac apps. The code keeps its original namespace.
        applicationId = "com.factadte.s1printer"
        minSdk = 26
        targetSdk = 36
        versionCode = 10
        versionName = "0.5.0"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    ndkVersion = "26.3.11579264"
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    signingConfigs {
        if (uploadProps.containsKey("storeFile")) create("upload") {
            storeFile = file(uploadProps.getProperty("storeFile"))
            storePassword = uploadProps.getProperty("storePassword")
            keyAlias = uploadProps.getProperty("keyAlias")
            keyPassword = uploadProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        getByName("release") {
            isMinifyEnabled = false
            signingConfigs.findByName("upload")?.let { signingConfig = it }
        }
    }
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
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
