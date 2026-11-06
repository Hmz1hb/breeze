import XCTest
@testable import FanCore

final class ActivityTests: XCTestCase {
    func testCPUUsesIntervalAndIncludesNiceInUser() throws {
        let sample = try XCTUnwrap(CPUActivity.between([130, 120, 140, 110], and: [100, 100, 100, 100]))
        XCTAssertEqual(sample.user, 40, accuracy: 0.001)
        XCTAssertEqual(sample.system, 20, accuracy: 0.001)
        XCTAssertEqual(sample.used, 60, accuracy: 0.001)
        XCTAssertEqual(sample.idle, 40, accuracy: 0.001)
        XCTAssertNil(CPUActivity.between([1, 2, 3, 4], and: nil))
        XCTAssertNil(CPUActivity.between([1, 2, 3, 4], and: [1, 2, 3, 4]))
    }

    func testCPUCounterWrap() throws {
        let sample = try XCTUnwrap(CPUActivity.between([5, 5, 5, 5], and: Array(repeating: UInt64(UInt32.max) - 4, count: 4)))
        XCTAssertEqual(sample.used, 75, accuracy: 0.001)
    }

    func testProcessCPUUsesElapsedTimeAndCanExceedOneCore() throws {
        let percent = ActivityProcess.cpuPercent(current: 6_000_000_000, previous: 1_000_000_000, elapsed: 2)
        XCTAssertEqual(try XCTUnwrap(percent), 250, accuracy: 0.001)
        XCTAssertNil(ActivityProcess.cpuPercent(current: 5, previous: nil, elapsed: 2))
        XCTAssertNil(ActivityProcess.cpuPercent(current: 5, previous: 10, elapsed: 2))
        XCTAssertNil(ActivityProcess.cpuPercent(current: 10, previous: 5, elapsed: 0))
    }

    func testProcessIdentityIncludesStartTime() {
        let first = ActivityProcess.ID(pid: 42, seconds: 100, microseconds: 1)
        let reused = ActivityProcess.ID(pid: 42, seconds: 200, microseconds: 1)
        XCTAssertNotEqual(first, reused)
    }

    func testLiveReaderMaintainsMemoryAndCPUInvariants() async throws {
        let reader = ActivityReader()
        let first = await reader.read(includeProcesses: true)
        XCTAssertNil(first.cpu)
        let memory = try XCTUnwrap(first.memory)
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        XCTAssertEqual(memory.available + memory.used, memory.total)
        let processes = try XCTUnwrap(first.processes)
        XCTAssertTrue(processes.contains { $0.pid == getpid() })
        XCTAssertTrue(processes.allSatisfy { $0.cpu == nil })
        // Exercise real process CPU time: catches treating Mach ticks as nanoseconds.
        let started = clock()
        while Double(clock() - started) < Double(CLOCKS_PER_SEC) / 10 {}
        try await Task.sleep(for: .milliseconds(30))
        let second = await reader.read(includeProcesses: true)
        let cpu = try XCTUnwrap(second.cpu)
        XCTAssertTrue((0...100).contains(cpu.used))
        let own = try XCTUnwrap(second.processes?.first { $0.pid == getpid() })
        XCTAssertNotNil(own.cpu)
        XCTAssertEqual(try XCTUnwrap(own.cpuTime), Double(clock()) / Double(CLOCKS_PER_SEC), accuracy: 0.03)
        XCTAssertGreaterThan(own.memory ?? 0, 0)
        XCTAssertGreaterThan(own.threads ?? 0, 0)
        print("Live activity: \(second.cores.count) cores, \(second.gpus.count) GPUs, \(second.processes?.count ?? 0) processes; GPU utilization \(second.gpus.first?.utilization.map { String($0) } ?? "unavailable"); pressure \(memory.pressure)")
    }
}
