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
