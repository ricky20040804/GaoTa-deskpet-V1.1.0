import AppKit

struct PetPackage {
    let id: String
    let displayName: String
    let description: String
    let spritesheetURL: URL?
    let actionSheetURLs: [Int: URL]

    private struct Manifest: Decodable {
        let id: String
        let displayName: String
        let description: String
        let spritesheetPath: String?
        let actionSheetPaths: ActionSheetPaths?
    }

    private struct ActionSheetPaths: Decodable {
        let idle: String
        let running: String
        let failed: String
        let tailWagging: String

        enum CodingKeys: String, CodingKey {
            case idle
            case running
            case failed
            case tailWagging = "tail-wagging"
        }
    }

    static func discoverPets() -> [PetPackage] {
        var packages: [PetPackage] = []
        let fileManager = FileManager.default
        let petsRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("pets")

        if let petDirs = try? fileManager.contentsOfDirectory(
            at: petsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in petDirs {
                if let package = load(from: dir) {
                    packages.append(package)
                }
            }
        }

        if packages.isEmpty, let bundled = bundledGoldie() {
            packages.append(bundled)
        }

        return packages.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func bundledGoldie() -> PetPackage? {
        guard let manifestURL = Bundle.main.url(forResource: "pet", withExtension: "json", subdirectory: "Pets/goldie") else {
            return nil
        }
        return load(fromManifest: manifestURL)
    }

    private static func load(from directory: URL) -> PetPackage? {
        load(fromManifest: directory.appendingPathComponent("pet.json"))
    }

    private static func load(fromManifest manifestURL: URL) -> PetPackage? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return nil
        }

        let directory = manifestURL.deletingLastPathComponent()
        let spritesheetURL = manifest.spritesheetPath.map { directory.appendingPathComponent($0) }
        let actionSheetURLs = actionSheetURLs(from: manifest.actionSheetPaths, in: directory)

        guard !actionSheetURLs.isEmpty || (spritesheetURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) else {
            return nil
        }

        return PetPackage(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            spritesheetURL: spritesheetURL,
            actionSheetURLs: actionSheetURLs
        )
    }

    private static func actionSheetURLs(from paths: ActionSheetPaths?, in directory: URL) -> [Int: URL] {
        guard let paths else { return [:] }

        let candidates: [Int: URL] = [
            0: directory.appendingPathComponent(paths.idle),
            1: directory.appendingPathComponent(paths.running),
            2: directory.appendingPathComponent(paths.failed),
            3: directory.appendingPathComponent(paths.tailWagging)
        ]

        guard candidates.values.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return [:]
        }
        return candidates
    }
}

enum PetAnimationState: String {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    // The 4x8 runtime keeps the historical state name for app events, but row 3 is tail-wagging art.
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review
}

final class PetAnimationPlayer {
    static let frameWidth: CGFloat = 192
    static let frameHeight: CGFloat = 192
    static let columns = 8
    static let rows = 4
    static let spritesheetWidth: CGFloat = 1536
    static let spritesheetHeight: CGFloat = 768

    private struct Animation {
        let row: Int
        let durations: [CFTimeInterval]
        let loops: Bool
        let fallback: PetAnimationState
        let flipped: Bool

        var totalDuration: CFTimeInterval {
            durations.reduce(0, +) / 1000
        }
    }

    private static let animations: [PetAnimationState: Animation] = [
        .idle: Animation(row: 0, durations: [160, 160, 160, 160, 160, 160, 160, 260], loops: true, fallback: .idle, flipped: false),
        .runningRight: Animation(row: 1, durations: [120, 120, 120, 120, 120, 120, 120, 220], loops: true, fallback: .idle, flipped: false),
        .runningLeft: Animation(row: 1, durations: [120, 120, 120, 120, 120, 120, 120, 220], loops: true, fallback: .idle, flipped: true),
        .waving: Animation(row: 3, durations: [140, 140, 140, 140, 140, 140, 140, 280], loops: false, fallback: .idle, flipped: false),
        .jumping: Animation(row: 3, durations: [140, 140, 140, 140, 140, 140, 140, 280], loops: false, fallback: .idle, flipped: false),
        .failed: Animation(row: 2, durations: [140, 140, 140, 140, 140, 140, 140, 240], loops: false, fallback: .idle, flipped: false),
        .waiting: Animation(row: 0, durations: [160, 160, 160, 160, 160, 160, 160, 260], loops: true, fallback: .idle, flipped: false),
        .running: Animation(row: 0, durations: [160, 160, 160, 160, 160, 160, 160, 260], loops: true, fallback: .idle, flipped: false),
        .review: Animation(row: 0, durations: [160, 160, 160, 160, 160, 160, 160, 260], loops: true, fallback: .idle, flipped: false)
    ]

    private weak var view: CharacterContentView?
    private var state: PetAnimationState = .idle
    private var animationStartedAt: CFTimeInterval = CACurrentMediaTime()
    private var lastRenderedFrame: (row: Int, column: Int)?
    private(set) var isOneShotActive = false

    init(view: CharacterContentView) {
        self.view = view
    }

    func play(_ newState: PetAnimationState, restart: Bool = true) {
        guard Self.animations[newState] != nil else { return }
        if !restart, state == newState { return }
        state = newState
        animationStartedAt = CACurrentMediaTime()
        isOneShotActive = !(Self.animations[newState]?.loops ?? true)
        lastRenderedFrame = nil
        tick(now: animationStartedAt)
    }

    func playLoop(_ newState: PetAnimationState) {
        guard !isOneShotActive else { return }
        play(newState, restart: false)
    }

    func tick(now: CFTimeInterval = CACurrentMediaTime()) {
        guard let animation = Self.animations[state] else { return }
        let elapsed = now - animationStartedAt
        let totalDuration = animation.totalDuration
        var localTime = elapsed

        if animation.loops {
            localTime = totalDuration > 0 ? elapsed.truncatingRemainder(dividingBy: totalDuration) : 0
        } else if elapsed >= totalDuration {
            isOneShotActive = false
            play(animation.fallback)
            return
        }

        let column = frameIndex(for: localTime, durations: animation.durations)
        let frame = (row: animation.row, column: column)
        if lastRenderedFrame?.row != frame.row || lastRenderedFrame?.column != frame.column {
            view?.showFrame(row: frame.row, column: frame.column, flipped: animation.flipped)
            lastRenderedFrame = frame
        }
    }

    private func frameIndex(for localTime: CFTimeInterval, durations: [CFTimeInterval]) -> Int {
        var cursor: CFTimeInterval = 0
        for (index, durationMS) in durations.enumerated() {
            cursor += durationMS / 1000
            if localTime < cursor {
                return index
            }
        }
        return max(durations.count - 1, 0)
    }
}
