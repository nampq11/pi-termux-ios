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
    dependencies: [
        // Terminal emulator for the SSH terminal screen (the bridge serves
        // /pty as a byte stream; SwiftTerm renders it). Pinned exactly:
        // 1.5.0+ manifests exclude the Apple/iOS sources when evaluated on
        // a Linux host (xtool cross-compiles from Linux), which drops the
        // UIKit TerminalView the app needs; 1.2.5 predates that exclusion
        // and guards platform files per-target instead.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.2.5"),
    ],
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
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [
                .copy("Resources/runtime.zip"),
                .copy("Resources/payload.sha256"),
            ]
        ),
    ]
)
