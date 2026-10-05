// swift-tools-version:5.9
// T2Kit: everything the T2 app does that is not user interface -- talking to the t2api
// service, holding columns, filtering samples (the Thanos cross-filter), statistics.
// No UIKit / SwiftUI here, so it builds and tests on Linux as well as on Apple platforms:
//   docker run --rm -v "$PWD":/pkg -w /pkg swift:6.0-jammy swift test
import PackageDescription

let package = Package(
    name: "T2Kit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "T2Kit", targets: ["T2Kit"])],
    targets: [
        .target(name: "T2Kit"),
        // a command-line check against a running service: swift run t2smoke http://host:port
        .executableTarget(name: "t2smoke", dependencies: ["T2Kit"]),
        .testTarget(name: "T2KitTests", dependencies: ["T2Kit"]),
    ]
)
