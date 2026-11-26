import XCTest
@testable import DepthStudio

final class PoolTimelineTests: XCTestCase {
    func testDemoTotalsMatchTheDesignExample() throws {
        // 50 m pool: 0 m at 00:02, 50 m at 00:50, 100 m at 01:40, 150 m at 02:30.
        let timeline = try PoolTimeline(session: .demo)
        XCTAssertEqual(timeline.finalDistance, 150)
        XCTAssertEqual(timeline.totalTime, 148, accuracy: 1e-9)
        XCTAssertEqual(timeline.averageSpeed, 150.0 / 148.0, accuracy: 1e-9)   // ≈ 1.014 m/s
        XCTAssertEqual(PoolFormat.speed(timeline.averageSpeed), "1.01")
        XCTAssertEqual(timeline.totalLaps, 3)
        XCTAssertEqual(timeline.segments.map { PoolFormat.speed($0.speed) }, ["1.04", "1.00", "1.00"])
    }

    func testDistanceAtEveryMarkedPointIsExact() throws {
        let timeline = try PoolTimeline(session: .demo)
        for point in timeline.points {
            XCTAssertEqual(timeline.distance(atVideoTime: point.time), point.distance, accuracy: 0.01)
        }
    }

    func testDistanceIsContinuousAndNeverGoesBackwards() throws {
        let timeline = try PoolTimeline(session: .demo)
        var previous = 0.0
        for step in 0...3200 {
            let distance = timeline.distance(atVideoTime: Double(step) * 0.05)
            XCTAssertGreaterThanOrEqual(distance, previous - 1e-9)
            XCTAssertLessThan(distance - previous, 0.2, "jump at \(Double(step) * 0.05)s")
            previous = distance
        }
        XCTAssertEqual(previous, 150, accuracy: 1e-9)
    }

    func testSimulatedSpeedVariesWithinPointThreeMetresPerSecond() throws {
        let timeline = try PoolTimeline(session: .demo)
        XCTAssertEqual(timeline.aiSegmentCount, 0)
        for segment in timeline.segments {
            let speeds = timeline.steps
                .filter { $0.startTime >= segment.startTime - 1e-9 && $0.endTime <= segment.endTime + 1e-9 }
                .map(\.speed)
            XCTAssertFalse(speeds.isEmpty)
            let deviations = speeds.map { abs($0 - segment.speed) }
            XCTAssertLessThanOrEqual(deviations.max() ?? 1, 0.3)
            XCTAssertGreaterThanOrEqual(deviations.max() ?? 0, 0.05, "speed should not stay fixed")
            XCTAssertGreaterThan(Set(speeds.map(PoolFormat.speed)).count, 8, "shown speed should change")
            XCTAssertTrue(speeds.allSatisfy { $0 > 0 })
        }
    }

    func testReadingsBeforeStartAndAfterFinish() throws {
        let timeline = try PoolTimeline(session: .demo)
        let before = timeline.reading(atVideoTime: 1)
        XCTAssertEqual(before.phase, .beforeStart)
        XCTAssertEqual(before.distance, 0)
        XCTAssertEqual(before.speed, 0)
        XCTAssertEqual(PoolFormat.lap(before), "01 / 03")
        let after = timeline.reading(atVideoTime: 200)
        XCTAssertEqual(after.phase, .finished)
        XCTAssertEqual(after.distance, 150)
        XCTAssertEqual(after.elapsedSeconds, 148, accuracy: 1e-9)
        XCTAssertEqual(PoolFormat.lap(after), "03 / 03")
    }

    func testLapCounting() throws {
        let timeline = try PoolTimeline(session: .demo)
        XCTAssertEqual(timeline.reading(atVideoTime: 30).lap, 1)
        XCTAssertEqual(timeline.reading(atVideoTime: 75).lap, 2)
        XCTAssertEqual(timeline.reading(atVideoTime: 149.9).lap, 3)
    }

    func testCustomFinalDistanceAndTwentyFiveMetrePool() throws {
        var session = PoolSession(poolLength: 50, finalDistance: 150)
        session.setFinalDistance(137.5)
        XCTAssertEqual(session.nodes.map(\.distance), [0, 50, 100, 137.5])
        XCTAssertEqual(session.nodes.last?.kind, .finish)
        session.setPoolLength(25)
        XCTAssertEqual(session.nodes.map(\.distance), [0, 25, 50, 75, 100, 125, 137.5])
        for (index, node) in session.nodes.enumerated() { session.setTime(Double(index) * 25, for: node.id) }
        let timeline = try PoolTimeline(session: session)
        XCTAssertEqual(timeline.totalLaps, 6)
        XCTAssertEqual(timeline.distance(atVideoTime: 1000), 137.5)
    }

    func testCheckpointsAndValidation() throws {
        var session = PoolSession(poolLength: 50, finalDistance: 100)
        XCTAssertThrowsError(try PoolTimeline(session: session)) { error in
            XCTAssertEqual(error as? PoolTimelineError, .missingStart)
        }
        XCTAssertTrue(session.addCheckpoint(distance: 25))
        XCTAssertFalse(session.addCheckpoint(distance: 25), "duplicate distance")
        XCTAssertFalse(session.addCheckpoint(distance: 100), "at the finish")
        let ids = session.nodes.map(\.id)   // 0, 25, 50, 100
        session.setTime(2, for: ids[0])
        session.setTime(30, for: ids[2])
        session.setTime(20, for: ids[1])
        XCTAssertThrowsError(try PoolTimeline(session: session)) { error in
            XCTAssertEqual(error as? PoolTimelineError, .missingFinish)
        }
        session.setTime(10, for: ids[3])
        XCTAssertThrowsError(try PoolTimeline(session: session)) { error in
            XCTAssertEqual(error as? PoolTimelineError, .timeNotIncreasing(distance: 100))
        }
        session.setTime(60, for: ids[3])
        XCTAssertNoThrow(try PoolTimeline(session: session))
    }

    func testAIMotionShapesTheSpeedButKeepsSegmentDistances() throws {
        let times = stride(from: 0.0, through: 160.0, by: 0.2).map { $0 }
        let values = times.map { 1 + 0.5 * sin($0 * 2) }
        let motion = PoolMotionSignal(times: times, values: values, detectionRate: 0.8)
        let timeline = try PoolTimeline(session: .demo, motion: motion)
        XCTAssertEqual(timeline.aiSegmentCount, 3)
        for point in timeline.points {
            XCTAssertEqual(timeline.distance(atVideoTime: point.time), point.distance, accuracy: 0.01)
        }
        // Faster where the measured motion is larger.
        let fast = timeline.reading(atVideoTime: 6 * .pi + .pi / 4).speed      // sin(2t) = 1, t ≈ 19.6 s
        let slow = timeline.reading(atVideoTime: 6 * .pi + 3 * .pi / 4).speed  // sin(2t) = -1, t ≈ 21.2 s
        XCTAssertGreaterThan(fast, slow + 0.3)
    }

    func testAIMotionOnlyCoveringPartOfTheSwimFallsBackPerSegment() throws {
        let times = stride(from: 0.0, through: 55.0, by: 0.2).map { $0 }
        let motion = PoolMotionSignal(times: times, values: times.map { 1 + 0.3 * sin($0) }, detectionRate: 0.5)
        let timeline = try PoolTimeline(session: .demo, motion: motion)
        XCTAssertEqual(timeline.segmentSources, [.ai, .simulated, .simulated])
    }

    func testTimeParsing() {
        XCTAssertEqual(PoolFormat.parseTime("01:40.5"), 100.5)
        XCTAssertEqual(PoolFormat.parseTime("100"), 100)
        XCTAssertEqual(PoolFormat.parseTime("1:02:30"), 3750)
        XCTAssertEqual(PoolFormat.parseTime("2：30"), 150)
        XCTAssertNil(PoolFormat.parseTime("abc"))
        XCTAssertNil(PoolFormat.parseTime(""))
        XCTAssertEqual(PoolFormat.preciseClock(100.5), "01:40.5")
    }
}
