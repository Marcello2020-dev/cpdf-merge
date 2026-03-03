// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vision-ocr-pdf-toolkit-core-tests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MergePipelineCore",
            targets: ["MergePipelineCore"]
        ),
    ],
    targets: [
        .target(
            name: "MergePipelineCore",
            path: "vision-ocr-pdf-toolkit",
            sources: [
                "PDFKitMerger.swift",
                "PDFKitOutline.swift",
                "MergePipelineService.swift",
            ]
        ),
        .testTarget(
            name: "MergePipelineCoreTests",
            dependencies: ["MergePipelineCore"],
            path: "Tests/MergePipelineCoreTests"
        ),
    ]
)
