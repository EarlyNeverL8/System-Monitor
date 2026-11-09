import Darwin
import Testing
@testable import System_Monitor

struct System_MonitorTests {
    @Test func cpuUsesIntervalAndIncludesNiceTime() {
        let before = CPUTicks(user: 1_000, system: 500, idle: 8_000, nice: 100)
        let after = CPUTicks(user: 1_020, system: 510, idle: 8_060, nice: 110)
        #expect(after.usage(since: before) == 40)
    }

    @Test func unchangedCountersHaveNoMeasurement() {
        let ticks = CPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        #expect(ticks.usage(since: ticks) == nil)
    }

    @Test func cpuCounterRolloverDoesNotOverflow() {
        let before = CPUTicks(user: UInt32.max - 4, system: 0, idle: 100, nice: 0)
        let after = CPUTicks(user: 5, system: 0, idle: 110, nice: 0)
        #expect(after.usage(since: before) == 50)
    }

    @Test func idleAndBusyIntervals() {
        let before = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        #expect(CPUTicks(user: 0, system: 0, idle: 10, nice: 0).usage(since: before) == 0)
        #expect(CPUTicks(user: 10, system: 0, idle: 0, nice: 0).usage(since: before) == 100)
    }

    @Test func memoryCountsPhysicalPagesAndExcludesPurgeablePages() {
        var vm = vm_statistics64()
        vm.internal_page_count = 100
        vm.purgeable_count = 20
        vm.wire_count = 30
        vm.compressor_page_count = 10
        vm.external_page_count = 500
        vm.total_uncompressed_pages_in_compressor = 100
        #expect(SystemInfoSampler.usedMemory(vm, pageSize: 16_384) == 120 * 16_384)
    }

    @Test func purgeablePagesCannotUnderflow() {
        var vm = vm_statistics64()
        vm.internal_page_count = 10
        vm.purgeable_count = 20
        vm.wire_count = 5
        #expect(SystemInfoSampler.usedMemory(vm, pageSize: 4_096) == 5 * 4_096)
    }

    @Test func liveSystemSampling() throws {
        var sampler = SystemInfoSampler()
        let first = sampler.sample()
        #expect(first.cpuUsage == nil)
        #expect(first.memoryTotal > 0)
        let used = try #require(first.memoryUsage)
        #expect(used > 0)
        #expect(used <= first.memoryTotal)
        #expect(first.diskSpaceAvailable != nil)
    }
}
