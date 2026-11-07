allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Some plugins still declare an old compileSdk; newer AndroidX libraries refuse to build
// against it. Lift every library module to the app level (now, or once it is evaluated).
subprojects {
    fun lift() {
        val android = extensions.findByName("android")
        if (android != null) {
            try { android.javaClass.getMethod("compileSdkVersion", Int::class.java).invoke(android, 36) } catch (_: Exception) {}
        }
    }
    if (state.executed) lift() else afterEvaluate { lift() }
}
