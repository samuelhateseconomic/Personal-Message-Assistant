// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageAssistant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MessageAssistant", targets: ["MessageAssistant"])],
    targets: [
        .target(name: "AssistantCore"),
        .target(name: "NativeServices", dependencies: ["AssistantCore"]),
        .executableTarget(name: "MessageAssistant", dependencies: ["AssistantCore", "NativeServices"]),
        .executableTarget(name: "NativeIntegrationChecks", dependencies: ["NativeServices"], path: "Tests/NativeIntegrationChecks"),
        .executableTarget(name: "AssistantCoreChecks", dependencies: ["AssistantCore"], path: "Tests/AssistantCoreTests")
    ]
)
