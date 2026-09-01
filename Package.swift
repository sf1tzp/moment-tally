// swift-tools-version:6.0
import Foundation
import PackageDescription

// Mac App Store variant (#115): `MOMENTTALLY_MAS=1 swift build` builds the
// store flavour. Sparkle must not merely be unused but unlinked — shipping
// an updater framework in a store build is a rejection — so the product
// dependency drops out of the app target and MAS_BUILD gates the sources
// (Updater.swift keeps a no-op stub half). The Sparkle *package* stays
// declared either way so Package.resolved never churns between variants;
// SwiftPM's "dependency 'Sparkle' is not used" warning in MAS builds is the
// accepted cost. Always give the variant its own scratch path
// (bundle-app.sh uses .build/mas) so object files built with different
// flags never mix.
let masBuild = ProcessInfo.processInfo.environment["MOMENTTALLY_MAS"] == "1"

let appDependencies: [Target.Dependency] = masBuild
    ? ["MomentTallyCore", "MomentTallyKit"]
    : ["MomentTallyCore", "MomentTallyKit",
       .product(name: "Sparkle", package: "Sparkle")]

// The app, the shared app layer, and the app test target need Apple
// frameworks (SwiftUI, Sparkle, the CloudKit fakes). Off-Mac hosts drop
// them from the manifest entirely — the manifest compiles on the build
// host, and iOS builds run from Mac hosts, so os(macOS) covers every
// Apple destination — which is what lets a plain `swift build` /
// `swift test` on a Linux runner cover MomentTallyCore, the CLI, and
// MomentTallyCoreTests (#85) instead of failing on SwiftUI first.
#if os(macOS)
let appleHostProducts: [Product] = [
    .executable(name: "MomentTally", targets: ["MomentTally"]),
    // The shared app layer (#123): the iOS app shell (ios/project.yml)
    // lives outside the package, so it cannot see `package`-access
    // symbols — SwiftPM derives -package-name from the checkout
    // directory, so Xcode's SWIFT_PACKAGE_NAME can't join it to the
    // boundary portably. The shell instead links this library and uses
    // its small public façade. #125 moves AppModel + the portable views
    // in here so both apps render the same files.
    .library(name: "MomentTallyKit", targets: ["MomentTallyKit"])
]
let appleHostTargets: [Target] = [
    .executableTarget(
        name: "MomentTally",
        dependencies: appDependencies,
        path: "Sources/MomentTally",
        exclude: ["README.md"],
        // Resources (brand art, license texts) live in the kit since
        // #125 — both apps render them. This target carries none.
        // MAS_BUILD switches Updater.swift to its Sparkle-free stub.
        swiftSettings: masBuild ? [.define("MAS_BUILD")] : [],
        linkerSettings: [
            // Sparkle.framework rides in the .app at Contents/Frameworks;
            // SwiftPM only adds an rpath into .build/artifacts (which also
            // keeps unbundled dev builds working), so add the bundle-
            // relative one ourselves.
            .unsafeFlags(["-Xlinker", "-rpath",
                          "-Xlinker", "@executable_path/../Frameworks"])
        ]
    ),
    // The shared app layer above core (#123/#124): AppModel and its
    // sub-models, the brand, and the portable launcher/popover
    // components — everything both apps render. The Mac target keeps
    // only its shell (MenuBarExtra, windows, Sparkle, login item) and
    // window-hosted views (#125 moves those too).
    .target(
        name: "MomentTallyKit",
        dependencies: ["MomentTallyCore"],
        path: "Sources/MomentTallyKit",
        exclude: ["README.md"],
        // The brand font (OFL text rides alongside) and the icon the
        // onboarding masthead draws. Resolved via Brand.resources, which
        // handles unbundled builds (swift run), the Mac .app (bundle-app.sh
        // copies the bundle into Contents/Resources), and the iOS app —
        // swift build's Bundle.module accessor can't find it there.
        resources: [
            .copy("Resources/AppIcon.icns"),
            // Masthead lockups: rasterised exports of the real brand
            // faces (the faces themselves stay unlicensed for embedding
            // — see Brand.swift). Light/dark pairs; regenerate from the
            // repo-root Resources/ masters with scripts/make-lockups.swift.
            .copy("Resources/Wordmark-dark.png"),
            .copy("Resources/Wordmark-light.png"),
            .copy("Resources/Tagline-dark.png"),
            .copy("Resources/Tagline-light.png"),
            .copy("Resources/Motif-dark.png"),
            .copy("Resources/Motif-light.png"),
            // License texts surfaced in Help → Acknowledgements (#115).
            // All ride in both variants (inert text either way); what
            // varies is the entry list in HelpView, where MAS_BUILD drops
            // Sparkle and argument-parser — the store binary contains
            // neither.
            .copy("Resources/GRDB-MIT.txt"),
            .copy("Resources/Sparkle-MIT.txt"),
            .copy("Resources/SwiftArgumentParser-Apache.txt")
        ],
        // HelpView's acknowledgements list drops Sparkle/argument-parser
        // entries in the store build, same define as the app target.
        swiftSettings: masBuild ? [.define("MAS_BUILD")] : []
    )
]
// The core test target carries the kit tests too (see MomentTallyCoreTests
// below); off-Mac the kit target is gone from the manifest, so the
// dependency drops with it.
let coreTestDependencies: [Target.Dependency] =
    ["MomentTallyCore", "MomentTallyKit"]
#else
let appleHostProducts: [Product] = []
let appleHostTargets: [Target] = []
let coreTestDependencies: [Target.Dependency] = ["MomentTallyCore"]
#endif

let package = Package(
    name: "MomentTally",
    platforms: [
        // macOS 14 gives us MenuBarExtra + the Observation framework (@Observable).
        .macOS(.v14),
        // iOS 17 pairs with macOS 14: CKSyncEngine (#121) and @Observable
        // share the same floor. Only MomentTallyCore builds for iOS; the two
        // executables stay Mac-only (the ios/ app shell links the library).
        .iOS(.v17)
    ],
    products: appleHostProducts + [
        // The scriptable CLI (#80). The product is `moment-tally-cli`, not
        // `moment-tally`: keeping the -cli suffix preserves the guard against
        // a case-insensitive .build/ collision with the app's binary (the
        // trap the pre-rename `primetime` product would have hit).
        // Distribution installs it under the plain name (see bundle-app.sh).
        .executable(name: "moment-tally-cli", targets: ["MomentTallyCLI"])
    ],
    dependencies: [
        // The local store (LocalBackend.swift): SQLite chosen over SwiftData
        // because GRDB records are plain Codable structs, so the existing
        // domain values persist without a mapping layer (see issue #23).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // In-app auto-update (issue #46). The SPM distribution is a prebuilt
        // XCFramework; bundle-app.sh copies it into Contents/Frameworks.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // Command parsing for the CLI target only.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        // The store and its domain (#80): everything the app and the CLI
        // share — domain types, the GRDB store, the export document, sync
        // bookkeeping, demo seeding. The cross-module surface uses `package`
        // access, so extracting the library makes nothing public API.
        .target(
            name: "MomentTallyCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MomentTallyCore",
            exclude: ["README.md"]
        ),
        // The scriptable surface (#80): export to stdout, timer start/stop/
        // status for scripts and agent hooks (#79). Talks to the same store
        // file the app uses, through the same MomentTallyCore code.
        .executableTarget(
            name: "MomentTallyCLI",
            dependencies: [
                "MomentTallyCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MomentTallyCLI",
            exclude: ["README.md"]
        ),
        // The whole suite: core + kit tests, deliberately free of the Mac
        // executable so it also runs against an iOS simulator destination
        // (#123). Since #125 moved the last app-layer types into the kit,
        // nothing tests the Mac shell itself and the old MomentTallyTests
        // target is gone; a future shell test would bring it back with a
        // "MomentTally" dependency. On Linux (#85) the kit drops out of the
        // manifest, and the CloudKit- and kit-backed test files gate
        // themselves out via canImport.
        .testTarget(
            name: "MomentTallyCoreTests",
            dependencies: coreTestDependencies +
                [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/MomentTallyCoreTests"
        )
    ] + appleHostTargets,
    // Tools 6.0 only for the Swift Testing integration; the code stays in the
    // Swift 5 language mode rather than adopting strict concurrency as a side
    // effect. With full Xcode, `swift test` just works; on a Command Line
    // Tools-only machine, point it at the CLT copy of Testing.framework:
    //   CLT=/Library/Developer/CommandLineTools
    //   swift test -Xswiftc -F -Xswiftc $CLT/Library/Developer/Frameworks \
    //     -Xlinker -F -Xlinker $CLT/Library/Developer/Frameworks \
    //     -Xlinker -rpath -Xlinker $CLT/Library/Developer/Frameworks \
    //     -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib
    swiftLanguageModes: [.v5]
)
