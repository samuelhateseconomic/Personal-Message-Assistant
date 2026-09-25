// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageAssistant",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MessageAssistant", targets: ["MessageAssistant"])],
    targets: [
        .target(name: "AssistantCore"),
        .executableTarget(name: "MessageAssistant", dependencies: ["AssistantCore"]),
        .executableTarget(name: "AssistantCoreChecks", dependencies: ["AssistantCore"], path: "Tests/AssistantCoreTests")
    ]
)
