// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhatsCranio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WhatsCranio", targets: ["WhatsCranio"])
    ],
    targets: [
        .executableTarget(
            name: "WhatsCranio",
            path: "Sources/WhatsCranio"
        ),
        .testTarget(
            name: "WhatsCranioTests",
            dependencies: ["WhatsCranio"],
            path: "Tests/WhatsCranioTests"
        )
    ]
)
