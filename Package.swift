// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Tally", targets: ["TallyApp"])],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", revision: "80b4445a88503fc6c8062ec40631eb7f9d93b837")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "TallyCore", dependencies: ["CSQLite"]),
        .target(name: "TallyHTTP", dependencies: ["TallyCore", .product(name: "Hummingbird", package: "hummingbird")]),
        .executableTarget(name: "TallyApp", dependencies: ["TallyCore", "TallyHTTP"], resources: [.copy("Resources/logos.json")]),
        .testTarget(name: "TallyTests", dependencies: ["TallyCore", "TallyHTTP", "TallyApp", "CSQLite", .product(name: "HummingbirdTesting", package: "hummingbird")], resources: [.copy("Fixtures")])
    ]
)
