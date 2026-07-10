// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "dtrexp-swift",
    products: [
        .library(name: "DTRExp", targets: ["DTRExp"])
    ],
    targets: [
        .target(name: "DTRExp"),
        .testTarget(
            name: "DTRExpTests",
            dependencies: ["DTRExp"],
            resources: [.copy("Resources/vectors.json")]
        )
    ]
)
