import Foundation

/// Polityka restartów pomocnika MediaRemote z sekcji 9 specu. Czysta logika, bez procesów.
struct HelperRestartPolicy {
    enum Outcome: Equatable {
        /// `/usr/bin/perl` nie istnieje albo proces się nie uruchomił.
        case launchFailed
        /// Kod wyjścia 3: brak symbolu MediaRemote.
        case unsupported
        /// Brak `hello` w 5 s, kod 2 albo koniec przed pierwszym `state`.
        case startFailure
        /// Koniec albo zabicie po co najmniej jednym `state`.
        case exitedAfterState
    }

    static let delays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
    static let maxStartFailures = 3

    private(set) var permanentlyDisabled = false
    private(set) var consecutiveStartFailures = 0
    private var delayIndex = 0

    /// Przerwa przed kolejnym startem albo nil, gdy pomocnik zostaje wyłączony do restartu aplikacji.
    mutating func record(_ outcome: Outcome) -> TimeInterval? {
        guard !permanentlyDisabled else { return nil }
        switch outcome {
        case .launchFailed, .unsupported:
            permanentlyDisabled = true
            return nil
        case .startFailure:
            consecutiveStartFailures += 1
            if consecutiveStartFailures >= Self.maxStartFailures {
                permanentlyDisabled = true
                return nil
            }
        case .exitedAfterState:
            break
        }
        let delay = Self.delays[min(delayIndex, Self.delays.count - 1)]
        delayIndex += 1
        return delay
    }

    /// Pierwszy `state` po starcie zeruje licznik porażek i przerwę.
    mutating func recordState() {
        consecutiveStartFailures = 0
        delayIndex = 0
    }

    /// `exitCode` -1 oznacza zakończenie sygnałem.
    static func outcome(exitCode: Int32, sawState: Bool) -> Outcome {
        if exitCode == 3 { return .unsupported }
        return sawState ? .exitedAfterState : .startFailure
    }
}

/// Nadzór nad pomocnikiem MediaRemote: proces, ostatni stan, okładki, komendy i restarty.
/// Cały stan żyje na prywatnej kolejce; publiczne metody są bezpieczne z każdego wątku.
final class MediaRemoteHelper {
    struct Launch {
        let executable: URL
        let arguments: [String]

        /// Pomocnik z paczki aplikacji uruchamiany przez systemowego perla.
        static func bundled(in bundle: Bundle = .main) -> Launch? {
            guard let resources = bundle.resourceURL else { return nil }
            let script = resources.appendingPathComponent("Helper/nowplaying-helper.pl")
            let library = resources.appendingPathComponent("Helper/NowPlayingHelper.dylib")
            let files = FileManager.default
            guard files.fileExists(atPath: script.path), files.fileExists(atPath: library.path) else { return nil }
            return Launch(executable: URL(fileURLWithPath: "/usr/bin/perl"), arguments: [script.path, library.path])
        }
    }

    struct Timing {
        var helloTimeout: TimeInterval = 5
        var freshness: TimeInterval = 5
        var silenceLimit: TimeInterval = 15
        var killGrace: TimeInterval = 2
        var ackTimeout: TimeInterval = 1
    }

    private struct PendingAck {
        let id: UUID
        let cmd: String
        let bundle: String
        let completion: (HelperCommandResult) -> Void
    }

    private let launch: Launch?
    private let timing: Timing
    private let queue = DispatchQueue(label: "wokyintosh.mediaremote-helper")

    private var policy = HelperRestartPolicy()
    private var running = false
    private var generation = 0
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    // Zegar systemowy (systemUptime), nie Date(): mach absolute time stoi w czasie snu,
    // więc po wybudzeniu Date() naliczyłby cały sen jako ciszę i zabił zdrowego pomocnika.
    // `lastStateAt` (świeżość stanu dla `freshPlayers`) zostaje na Date(), bo to porównanie z zegarem ściennym.
    private var startedAt: TimeInterval = 0
    private var lastLineAt: TimeInterval = 0
    private var sawHello = false
    private var sawState = false
    private var players: [MRPlayer] = []
    private var lastStateAt: Date?
    private var artworks: [String: MRArtwork] = [:]
    private var pendingAcks: [PendingAck] = []
    private var watchdog: DispatchSourceTimer?
    // Koniec procesu liczymy dopiero, gdy mamy i kod wyjścia, i zamknięte wyjście
    // (albo minęła 1 s bez EOF) — inaczej spóźniona linia z umierającego procesu
    // mogłaby wrócić po `clearState()` i zostawić fantomowy stan.
    private var pendingExitCode: Int32?
    private var outputClosed = false
    private var exitHandled = false

    init(launch: Launch?, timing: Timing = Timing()) {
        self.launch = launch
        self.timing = timing
    }

    var isPermanentlyDisabled: Bool {
        queue.sync { policy.permanentlyDisabled }
    }

    func start() {
        // Zapis do potoku martwego pomocnika nie może zabić aplikacji sygnałem.
        signal(SIGPIPE, SIG_IGN)
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.launchProcess()
        }
    }

    /// Zamyka wejście pomocnika (sam wtedy wychodzi), czeka do 1 s, potem SIGTERM.
    func stop() {
        let finished: Process? = queue.sync {
            running = false
            generation += 1
            watchdog?.cancel()
            watchdog = nil
            failPendingAcks()
            clearState()
            try? input?.close()
            input = nil
            let current = process
            process = nil
            return current
        }
        guard let finished else { return }
        let deadline = Date().addingTimeInterval(1)
        while finished.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if finished.isRunning {
            finished.terminate()
        }
    }

    /// Odtwarzacze z ostatniego `state`, jeśli przyszedł mniej niż `freshness` sekund temu.
    func freshPlayers(now: Date = Date()) -> [MRPlayer]? {
        queue.sync {
            guard let lastStateAt, now.timeIntervalSince(lastStateAt) < timing.freshness else { return nil }
            return players
        }
    }

    func artwork(id: String) -> MRArtwork? {
        guard !id.isEmpty else { return nil }
        return queue.sync { artworks.values.first { $0.artworkId == id } }
    }

    /// Komenda tylko do odtwarzacza z ostatniego stanu. `completion(.ok)` wyłącznie po `ack`
    /// z `ok:true`; `.rejected` gdy komenda jest niewysyłalna albo `ack` przyszedł z `ok:false`;
    /// `.timedOut`, gdy `ack` nie przyszedł w czasie `ackTimeout`. Wołane na kolejce globalnej.
    func send(_ command: MRCommand, bundle: String, completion: @escaping (HelperCommandResult) -> Void) {
        queue.async {
            guard let input = self.input, self.players.contains(where: { $0.bundle == bundle }) else {
                DispatchQueue.global(qos: .userInitiated).async { completion(.rejected) }
                return
            }
            let pending = PendingAck(id: UUID(), cmd: command.rawValue, bundle: bundle, completion: completion)
            self.pendingAcks.append(pending)
            do {
                try input.write(contentsOf: MediaRemoteProtocol.encode(command: command, bundle: bundle))
            } catch {
                self.resolveAck(id: pending.id, result: .rejected)
                return
            }
            self.queue.asyncAfter(deadline: .now() + self.timing.ackTimeout) {
                self.resolveAck(id: pending.id, result: .timedOut)
            }
        }
    }

    private func launchProcess() {
        guard running, process == nil, !policy.permanentlyDisabled else { return }
        guard let launch else {
            _ = policy.record(.launchFailed)
            NSLog("Wokyintosh: brak plików pomocnika Now Playing, zostaje AppleScript")
            return
        }

        generation += 1
        let current = generation
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self?.queue.async { self?.receive(chunk, generation: current) }
        }
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationReason == .exit ? finished.terminationStatus : -1
            self?.queue.async { self?.recordExit(code: code, generation: current) }
        }

        // Defensywnie: żaden stan po poprzednim procesie nie ma prawa przetrwać do nowego.
        clearState()
        sawHello = false
        sawState = false
        startedAt = ProcessInfo.processInfo.systemUptime
        lastLineAt = startedAt
        pendingExitCode = nil
        outputClosed = false
        exitHandled = false

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            _ = policy.record(.launchFailed)
            NSLog("Wokyintosh: pomocnik Now Playing nie wystartował (\(error)), zostaje AppleScript")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        startWatchdog(generation: current)
    }

    private func receive(_ chunk: Data, generation current: Int) {
        guard current == generation else { return }
        guard !chunk.isEmpty else {
            // Puste dane to EOF potoku: koniec wyjścia dla tej generacji.
            outputClosed = true
            finishExitIfReady(generation: current)
            return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
        // Linia ponad limit i tak nie przejdzie parsowania; nie trzymamy jej w pamięci.
        if buffer.count > MediaRemoteProtocol.maxLineBytes {
            buffer.removeAll()
        }
    }

    private func handle(line: Data) {
        lastLineAt = ProcessInfo.processInfo.systemUptime
        guard let message = MediaRemoteProtocol.parse(line: line) else { return }
        switch message {
        case .hello:
            sawHello = true
        case .state(let current):
            players = current
            lastStateAt = Date()
            if !sawState {
                sawState = true
                policy.recordState()
            }
            let present = Set(current.map(\.bundle))
            artworks = artworks.filter { present.contains($0.key) }
        case .artwork(let artwork):
            artworks[artwork.bundle] = artwork
        case .ack(let cmd, let bundle, let ok):
            if let pending = pendingAcks.first(where: { $0.cmd == cmd && $0.bundle == bundle }) {
                resolveAck(id: pending.id, result: ok ? .ok : .rejected)
            }
        case .error(let reason, let symbol):
            NSLog("Wokyintosh: pomocnik Now Playing zgłosił \(reason) \(symbol)")
        }
    }

    private func startWatchdog(generation current: Int) {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.checkHealth(generation: current)
        }
        watchdog = timer
        timer.resume()
    }

    private func checkHealth(generation current: Int) {
        guard current == generation, let process else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let helloMissing = !sawHello && now - startedAt >= timing.helloTimeout
        let silent = now - lastLineAt >= timing.silenceLimit
        guard helloMissing || silent else { return }

        watchdog?.cancel()
        watchdog = nil
        NSLog("Wokyintosh: pomocnik Now Playing \(helloMissing ? "nie przysłał hello" : "milczy"), zatrzymuję")
        process.terminate()
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + timing.killGrace) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Zapamiętuje kod wyjścia; samo zakończenie odpala dopiero `finishExitIfReady`,
    /// gdy doszło też EOF potoku (albo po 1 s, gdyby wnuk procesu trzymał go otwarty).
    private func recordExit(code: Int32, generation current: Int) {
        guard current == generation else { return }
        pendingExitCode = code
        if outputClosed {
            finishExit(generation: current)
        } else {
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.finishExit(generation: current)
            }
        }
    }

    private func finishExitIfReady(generation current: Int) {
        guard current == generation, pendingExitCode != nil else { return }
        finishExit(generation: current)
    }

    private func finishExit(generation current: Int) {
        guard current == generation, !exitHandled, let code = pendingExitCode else { return }
        exitHandled = true
        // Podbijamy generację od razu: spóźnione zdarzenia z martwego procesu mają być ignorowane.
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        process = nil
        try? input?.close()
        input = nil
        failPendingAcks()
        clearState()
        let delay = policy.record(HelperRestartPolicy.outcome(exitCode: code, sawState: sawState))
        if let delay {
            NSLog("Wokyintosh: pomocnik Now Playing zakończył się (kod \(code)), restart za \(Int(delay)) s")
        } else {
            NSLog("Wokyintosh: pomocnik Now Playing zakończył się (kod \(code)), zostaje AppleScript")
        }
        guard running, let delay else { return }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchProcess()
        }
    }

    private func clearState() {
        players = []
        lastStateAt = nil
        artworks = [:]
        buffer = Data()
    }

    private func resolveAck(id: UUID, result: HelperCommandResult) {
        guard let index = pendingAcks.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingAcks.remove(at: index)
        DispatchQueue.global(qos: .userInitiated).async { pending.completion(result) }
    }

    /// Wołane, gdy pomocnik kończy działanie albo zostaje zatrzymany: to nie timeout,
    /// więc dogrywka AppleScriptem dla wybranego odtwarzacza wciąż ma sens.
    private func failPendingAcks() {
        for pending in pendingAcks {
            resolveAck(id: pending.id, result: .rejected)
        }
    }
}
