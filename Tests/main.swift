import Foundation

var failures = 0
var checks = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(label): otrzymano \(actual), oczekiwano \(expected)")
    }
}

func assertClose(_ actual: Double, _ expected: Double, _ label: String, tolerance: Double = 0.05) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL \(label): otrzymano \(actual), oczekiwano \(expected) ±\(tolerance)")
    }
}

func finishTests() -> Never {
    print(failures == 0 ? "OK: \(checks) sprawdzeń" : "\(failures) z \(checks) sprawdzeń nie przeszło")
    exit(failures == 0 ? 0 : 1)
}

// CPU: kolejność wartości jest taka jak w host_cpu_load_info,
// czyli [user, system, idle, nice].
assertClose(
    SystemMonitor.cpuPercent(previous: [100, 50, 800, 50], current: [200, 100, 1600, 100]),
    20.0,
    "cpu: normalna różnica"
)
assertClose(
    SystemMonitor.cpuPercent(previous: [UInt32.max - 10, 0, 0, 0], current: [9, 0, 100, 0]),
    16.666,
    "cpu: przekręcenie licznika"
)
assertClose(
    SystemMonitor.cpuPercent(previous: [5, 5, 5, 5], current: [5, 5, 5, 5]),
    0.0,
    "cpu: brak zmian"
)

// RAM: liczby z tego Maca z 2026-09-15 (strona 16 KiB, 16 GiB pamięci).
// internal 336758, purgeable 6404, wired 142265, compressor 263200 stron.
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 336_758, purgeablePages: 6_404,
        wiredPages: 142_265, compressorPages: 263_200,
        pageSize: 16_384, totalBytes: 17_179_869_184
    ),
    70.17,
    "ram: wzór jak w Monitorze aktywności",
    tolerance: 0.1
)
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 10, purgeablePages: 999,
        wiredPages: 0, compressorPages: 0,
        pageSize: 16_384, totalBytes: 17_179_869_184
    ),
    0.0,
    "ram: purgeable większe od internal nie daje ujemnego wyniku"
)
assertClose(
    SystemMonitor.memoryPercent(
        internalPages: 1, purgeablePages: 0,
        wiredPages: 0, compressorPages: 0,
        pageSize: 16_384, totalBytes: 0
    ),
    0.0,
    "ram: zerowa pamięć całkowita"
)

// Liczby z AppleScript. Przy locale innym niż amerykańskie (u nas en_PL)
// AppleScript skleja liczby z przecinkiem, np. "214,740997314453".
assertClose(NowPlayingMonitor.parseNumber("214,740997314453"), 214.741, "muzyka: liczba z przecinkiem", tolerance: 0.001)
assertClose(NowPlayingMonitor.parseNumber("17.427000045776"), 17.427, "muzyka: liczba z kropką", tolerance: 0.001)
assertClose(NowPlayingMonitor.parseNumber(" 42 "), 42.0, "muzyka: liczba ze spacjami")
assertClose(NowPlayingMonitor.parseNumber(""), 0.0, "muzyka: pusty tekst")
assertClose(NowPlayingMonitor.parseNumber("brak"), 0.0, "muzyka: tekst bez liczby")

finishTests()
