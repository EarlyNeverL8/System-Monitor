import Foundation
import Testing
@testable import System_Monitor

// MARK: - Speed test parsing & ratings
struct SpeedTestTests {
    @Test func parsesOoklaProgressAndResultLines() throws {
        let start = #"{"type":"testStart","isp":"Fibre Co","server":{"name":"Openserve","location":"Cape Town"}}"#
        #expect(SpeedTestParser.parse(start) == .started(server: "Openserve · Cape Town", isp: "Fibre Co"))

        // 12,500,000 bytes/s = 100 Mbps.
        let download = #"{"type":"download","download":{"bandwidth":12500000,"progress":0.5}}"#
        #expect(SpeedTestParser.parse(download) == .progress(.download, fraction: 0.5, value: 100))

        let result = #"""
        {"type":"result","ping":{"jitter":1.2,"latency":8.4},"download":{"bandwidth":12500000},
         "upload":{"bandwidth":2500000},"packetLoss":0,"isp":"Fibre Co",
         "server":{"name":"Openserve","location":"Cape Town"},"result":{"url":"https://www.speedtest.net/result/c/abc"}}
        """#.replacingOccurrences(of: "\n", with: "")
        guard case .finished(let final)? = SpeedTestParser.parse(result) else {
            Issue.record("Expected a result"); return
        }
        #expect(final.download == 100)
        #expect(final.upload == 20)
        #expect(final.ping == 8.4)
        #expect(final.resultURL?.host == "www.speedtest.net")
        #expect(SpeedTestParser.parse("not json") == nil)
    }

    @Test func ratesFastLowLatencyLinksExcellentAndSlowLinksPoor() {
        let fast = SpeedTestResult(ping: 9, jitter: 1, download: 300, upload: 60, packetLoss: 0)
        #expect(ConnectionRatings.ratings(for: fast).allSatisfy { $0.quality >= .good })
        #expect(ConnectionRatings.ratings(for: fast).first { $0.activity == "Online gaming" }?.quality == .excellent)

        let slow = SpeedTestResult(ping: 180, jitter: 60, download: 2, upload: 0.3, packetLoss: 5)
        #expect(ConnectionRatings.ratings(for: slow).allSatisfy { $0.quality == .poor })
        #expect(ConnectionRatings.signal(rssi: -45) == .excellent)
        #expect(ConnectionRatings.signal(rssi: -75) == .poor)
    }
}

// MARK: - Battery & formatting
struct BatteryAndFormatTests {
    @Test func batteryHealthUsesNominalOverDesignCapacity() {
        let properties: [String: Any] = [
            "CurrentCapacity": 80, "MaxCapacity": 100, "CycleCount": 321, "DesignCycleCount9C": 1000,
            "IsCharging": true, "ExternalConnected": true, "FullyCharged": false, "TimeRemaining": 65535,
            "BatteryData": ["DesignCapacity": 6249, "NominalChargeCapacity": 5453]
        ]
        let info = BatteryInfo.make(from: properties, powerSourceHealth: "Good")
        #expect(info.healthPercent == 87)
        #expect(info.chargePercent == 80)
        #expect(info.condition == "Normal")
        #expect(info.minutesRemaining == nil)            // 65535 means "still calculating"
        #expect(BatteryInfo.make(from: properties, powerSourceHealth: "Poor").condition == "Service Recommended")
    }

    @Test func storageSummaryReadsLikeFinder() {
        #expect(Format.storageSummary(available: 260_000_000_000, total: 500_000_000_000) == "260 GB of 500 GB available")
        // Decimal separators follow the user's region ("1.2" or "1,2").
        let decimal = { (value: Double) in value.formatted(.number.precision(.fractionLength(0...1))) }
        #expect(Format.storage(1_200_000_000_000) == decimal(1.2) + " TB")
        #expect(Format.storage(45_300_000_000) == decimal(45.3) + " GB")
    }

    @Test func hardwareInfoDescribesThisMac() {
        let hardware = HardwareInfo.current
        #expect(hardware.totalCores > 0)
        #expect(hardware.coreSummary.contains("-core CPU"))
    }

    @Test func networkCountersAreReadable() {
        #expect(NetworkCounters.read() != nil)
    }
}
