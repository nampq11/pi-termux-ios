// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PiMobile",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "PiMobile",
            targets: ["PiMobile"]
        ),
    ],
    dependencies: [],
    targets: [
        // Node.js engine (nodejs-mobile, Node 24 LTS) downloaded by
        // scripts/prepare-runtime-ios.py; runs the bridge in-process.
        .binaryTarget(
            name: "NodeMobile",
            path: "Frameworks/NodeMobile.xcframework"
        ),
        .target(
            name: "PiMobile",
            dependencies: [
                "NodeMobile",
            ],
            resources: [
                .copy("Resources/runtime.zip"),
                .copy("Resources/payload.sha256"),
            ]
        ),
    ]
)
