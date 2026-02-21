// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FieldSurveyApp",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "FieldSurveyApp",
            targets: ["FieldSurveyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apache/arrow-swift.git", branch: "main")
    ],
    targets: [
        .target(
            name: "FieldSurveyApp",
            dependencies: [
                .product(name: "Arrow", package: "arrow-swift")
            ])
    ]
)
