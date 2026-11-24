import Foundation

struct CleanupRule: Sendable {
    let title: String
    let path: String
    var category: CleanupCategory = .developer
    var risk: CleanupRisk = .rebuildable
    var detail = "Downloaded packages and build cache. Close the tool and stop builds before removing it."
    var recovery = "Downloaded or rebuilt when the tool next needs it; internet access may be required."
    var children = false
    var owners: [String] = []
    var processes: [String] = []
}

enum CleanupCatalog {
    // Only disposable subdirectories, never entire tool homes containing credentials,
    // source checkouts, installed SDKs, databases, or AI conversation history.
    static let rules: [CleanupRule] = [
        .init(title: "npm package cache", path: ".npm/_cacache", processes: ["node", "npm"]),
        .init(title: "npm logs", path: ".npm/_logs", risk: .review,
              detail: "npm diagnostic logs. Keep them if you are investigating an install failure.",
              recovery: "New logs are generated. Existing logs can only be restored from Trash.", processes: ["npm"]),
        .init(title: "pnpm store", path: "Library/pnpm/store", risk: .review,
              detail: "pnpm's shared package store. Some projects link here. Prefer pnpm store prune if you need to keep those links intact.", processes: ["node", "pnpm"]),
        .init(title: "pnpm cache", path: "Library/Caches/pnpm", processes: ["node", "pnpm"]),
        .init(title: "Yarn download cache", path: "Library/Caches/Yarn", processes: ["node", "yarn"]),
        .init(title: "Bun install cache", path: ".bun/install/cache", risk: .review, processes: ["bun"]),
        .init(title: "Homebrew downloads", path: "Library/Caches/Homebrew", processes: ["brew"]),
        .init(title: "CocoaPods cache", path: "Library/Caches/CocoaPods", processes: ["ruby", "pod"]),
        .init(title: "SwiftPM cache", path: "Library/Caches/org.swift.swiftpm", processes: ["swift", "swift-frontend", "xcodebuild"]),
        .init(title: "SwiftPM downloads", path: ".swiftpm/cache", processes: ["swift", "xcodebuild"]),
        .init(title: "Cargo registry downloads", path: ".cargo/registry/cache", processes: ["cargo", "rustc"]),
        .init(title: "Cargo registry sources", path: ".cargo/registry/src", risk: .review, processes: ["cargo", "rustc"]),
        .init(title: "rustup downloads", path: ".rustup/downloads", processes: ["rustup"]),
        .init(title: "rustup temporary files", path: ".rustup/tmp", risk: .review, processes: ["rustup"]),
        .init(title: "Gradle caches", path: ".gradle/caches", risk: .review, processes: ["java", "gradle"]),
        .init(title: "Gradle distribution downloads", path: ".gradle/wrapper/dists", processes: ["java", "gradle"]),
        .init(title: "Maven local repository", path: ".m2/repository", risk: .review,
              detail: "Downloaded dependencies and possibly locally published artifacts. Local-only artifacts cannot be downloaded again.", processes: ["java", "mvn"]),
        .init(title: "pip cache", path: "Library/Caches/pip", processes: ["pip", "python", "python3"]),
        .init(title: "pip cache", path: ".cache/pip", processes: ["pip", "python", "python3"]),
        .init(title: "uv cache", path: ".cache/uv", risk: .review, processes: ["uv", "python", "python3"]),
        .init(title: "Conda package downloads", path: "miniconda3/pkgs", risk: .review,
              detail: "Conda's shared package cache. Check environments before removing; conda clean is preferable for linked packages.", processes: ["conda", "python", "python3"]),
        .init(title: "Conda package downloads", path: "anaconda3/pkgs", risk: .review, processes: ["conda", "python", "python3"]),
        .init(title: "Go build cache", path: "Library/Caches/go-build", processes: ["go", "compile"]),
        .init(title: "Go module download cache", path: "go/pkg/mod/cache/download", processes: ["go"]),
        .init(title: "NuGet HTTP cache", path: ".local/share/NuGet/http-cache", processes: ["dotnet"]),
        .init(title: "NuGet packages", path: ".nuget/packages", risk: .review, processes: ["dotnet"]),
        .init(title: "Dart & Flutter packages", path: ".pub-cache", risk: .review,
              detail: "Shared pub packages, including any globally activated tools. Re-run pub get or reactivate tools after removal.", processes: ["dart", "flutter"]),
        .init(title: "nvm download cache", path: ".nvm/.cache", processes: ["node", "nvm"]),
        .init(title: "Volta temporary downloads", path: ".volta/tmp", risk: .review, processes: ["volta"]),
        .init(title: "Playwright browsers", path: "Library/Caches/ms-playwright", risk: .review,
              recovery: "Run playwright install again before browser tests.", processes: ["node", "playwright", "chrome", "firefox", "webkit"]),
        .init(title: "Puppeteer browsers", path: ".cache/puppeteer", risk: .review,
              recovery: "Reinstall the browsers with Puppeteer before running automation.", processes: ["node", "chrome"]),
        .init(title: "Cypress binaries", path: "Library/Caches/Cypress", risk: .review,
              recovery: "Run cypress install before running Cypress again.", processes: ["node", "Cypress"]),
        .init(title: "Android SDK download cache", path: ".android/cache", owners: ["com.google.android.studio"], processes: ["java", "sdkmanager"]),
        .init(title: "Android SDK temporary files", path: "Library/Android/sdk/.temp", risk: .review,
              owners: ["com.google.android.studio"], processes: ["java", "sdkmanager"]),
        .init(title: "JetBrains cache", path: "Library/Caches/JetBrains", risk: .review, children: true, processes: ["idea", "java"]),
        .init(title: "VS Code cache", path: "Library/Application Support/Code/Cache", category: .appCaches, owners: ["com.microsoft.VSCode"]),
        .init(title: "VS Code cached downloads", path: "Library/Application Support/Code/CachedData", category: .appCaches, owners: ["com.microsoft.VSCode"]),
        .init(title: "Cursor cache", path: "Library/Application Support/Cursor/Cache", category: .appCaches, owners: ["com.todesktop.230313mzl4w4u92"]),
        .init(title: "Windsurf cache", path: "Library/Application Support/Windsurf/Cache", category: .appCaches, owners: ["com.exafunction.windsurf"]),
        .init(title: "Claude Code debug logs", path: ".claude/debug", risk: .review,
              detail: "Diagnostic logs from Claude Code. These may be useful when investigating a problem.",
              recovery: "New logs are generated; old diagnostic history is only recoverable from Trash.", processes: ["claude"]),
        .init(title: "Codex logs", path: ".codex/log", risk: .review,
              detail: "Codex diagnostic logs. Sessions, credentials, skills and configuration are kept.",
              recovery: "New logs are generated; old diagnostic history is only recoverable from Trash.", processes: ["codex"]),
        .init(title: "Claude app cache", path: "Library/Application Support/Claude/Cache", category: .appCaches, owners: ["com.anthropic.claudefordesktop"]),
        .init(title: "Xcode DerivedData", path: "Library/Developer/Xcode/DerivedData", category: .xcode,
              detail: "Per-project build products, indexes and intermediate files. The next build may take longer.", children: true,
              owners: ["com.apple.dt.Xcode"], processes: ["xcodebuild", "swift-frontend", "clang"]),
        .init(title: "Xcode device support", path: "Library/Developer/Xcode/iOS DeviceSupport", category: .xcode, risk: .review,
              detail: "Debugging support for a connected iOS version. Keep versions you still develop against.", children: true,
              owners: ["com.apple.dt.Xcode"], processes: ["xcodebuild"]),
        .init(title: "Xcode archive", path: "Library/Developer/Xcode/Archives", category: .xcode, risk: .personal,
              detail: "Release archives and debug symbols. These may be needed for distribution and crash symbolication.",
              recovery: "Restore from Trash or a backup. An identical archive may not be reproducible.", children: true,
              owners: ["com.apple.dt.Xcode"], processes: ["xcodebuild"]),
        .init(title: "Xcode documentation cache", path: "Library/Developer/Xcode/DocumentationCache", category: .xcode,
              detail: "Downloaded and indexed developer documentation. Xcode rebuilds it when documentation is next opened.",
              owners: ["com.apple.dt.Xcode"]),
        .init(title: "Simulator logs", path: "Library/Logs/CoreSimulator", category: .xcode, risk: .review,
              detail: "Simulator and device diagnostic logs. Keep them if you are investigating a simulator crash.",
              recovery: "New logs are generated. Existing logs can only be restored from Trash.",
              owners: ["com.apple.iphonesimulator"], processes: ["simctl"])
    ]

    struct ProjectRule: Sendable {
        let name: String
        let markers: [String]
        let detail: String
        let recovery: String
        var risk: CleanupRisk = .review
        var processes: [String] = []
    }

    static let projects: [ProjectRule] = [
        .init(name: "node_modules", markers: ["package.json"], detail: "Installed dependencies for this project. Check for local edits or linked packages.",
              recovery: "Run this project's package-manager install command.", processes: ["node", "npm", "pnpm", "yarn", "bun"]),
        .init(name: ".next", markers: ["package.json"], detail: "Next.js build output and cache.", recovery: "Rebuilt by Next.js.", risk: .rebuildable, processes: ["node", "bun"]),
        .init(name: ".nuxt", markers: ["package.json"], detail: "Nuxt's generated build workspace.", recovery: "Regenerated by Nuxt.", risk: .rebuildable, processes: ["node", "bun"]),
        .init(name: ".turbo", markers: ["package.json", "turbo.json"], detail: "Turborepo's local build cache.", recovery: "Rebuilt on the next task run.", risk: .rebuildable, processes: ["node", "turbo"]),
        .init(name: "Pods", markers: ["Podfile"], detail: "CocoaPods project dependencies. Keep any locally edited pod sources.", recovery: "Run pod install with the project's lockfile.", processes: ["ruby", "pod", "xcodebuild"]),
        .init(name: ".build", markers: ["Package.swift"], detail: "Swift package build products and dependency checkouts. Check for local edits in checkouts.", recovery: "Recreated by swift build; dependencies may need downloading.", processes: ["swift", "swift-frontend", "xcodebuild"]),
        .init(name: "target", markers: ["Cargo.toml", "pom.xml"], detail: "Rust or Maven build output. This can include locally important build artifacts.", recovery: "Rebuild with cargo or Maven.", processes: ["cargo", "rustc", "java", "mvn"]),
        .init(name: ".venv", markers: ["pyproject.toml", "requirements.txt", "Pipfile", "setup.py"], detail: "A Python virtual environment. Check for editable installs, notebooks or locally stored data.", recovery: "Recreate the environment and reinstall locked dependencies.", processes: ["python", "python3", "uv", "pip"]),
        .init(name: "venv", markers: ["pyproject.toml", "requirements.txt", "Pipfile", "setup.py"], detail: "A Python virtual environment. Locally installed packages may not be reproducible.", recovery: "Recreate the environment and reinstall dependencies.", processes: ["python", "python3", "uv", "pip"]),
        .init(name: "__pycache__", markers: [], detail: "Compiled Python bytecode; original source files stay in the project.", recovery: "Rebuilt when Python imports the source.", risk: .rebuildable, processes: ["python", "python3"]),
        .init(name: ".dart_tool", markers: ["pubspec.yaml"], detail: "Dart and Flutter generated tool metadata and build cache.", recovery: "Run flutter pub get or dart pub get.", risk: .rebuildable, processes: ["dart", "flutter"]),
        .init(name: "build", markers: ["pubspec.yaml", "build.gradle", "build.gradle.kts"], detail: "Flutter or Gradle build output. Check for exported artifacts you want to keep.", recovery: "Rebuild the project.", processes: ["dart", "flutter", "java", "gradle"]),
        .init(name: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], detail: "Per-project Gradle task cache.", recovery: "Recreated on the next Gradle build.", risk: .rebuildable, processes: ["java", "gradle"])
    ]
}
