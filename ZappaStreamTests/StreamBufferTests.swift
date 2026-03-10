#if os(macOS)
import XCTest
@testable import ZappaStream

final class StreamBufferTests: XCTestCase {

    // MARK: - init clamping

    func testInit_clampsMinimum() {
        let buf = StreamBuffer(maxMinutes: 3)
        XCTAssertEqual(buf.maxSegments, 5)
    }

    func testInit_clampsMaximum() {
        let buf = StreamBuffer(maxMinutes: 35)
        XCTAssertEqual(buf.maxSegments, 30)
    }

    func testInit_withinRange() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.maxSegments, 15)
    }

    func testInit_lowerBound() {
        let buf = StreamBuffer(maxMinutes: 5)
        XCTAssertEqual(buf.maxSegments, 5)
    }

    func testInit_upperBound() {
        let buf = StreamBuffer(maxMinutes: 30)
        XCTAssertEqual(buf.maxSegments, 30)
    }

    func testInit_defaultValue() {
        let buf = StreamBuffer()
        XCTAssertEqual(buf.maxSegments, 15)
    }

    // MARK: - bufferedDuration formula

    func testBufferedDuration_zero() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.bufferedDuration, 0.0)
    }

    func testBytesPerSecond_correct() {
        let buf = StreamBuffer(maxMinutes: 15)
        // 44100 Hz * 2 channels * 2 bytes/sample (Int16) = 176400 B/s
        XCTAssertEqual(buf.bytesPerSecond, 176_400)
    }

    func testSamplesPerSegment_correct() {
        let buf = StreamBuffer(maxMinutes: 15)
        // 60 s * 44100 Hz * 2 channels = 5_292_000 samples
        XCTAssertEqual(buf.samplesPerSegment, 5_292_000)
    }

    func testCurrentTimestamp_aliasesBufferedDuration() {
        let buf = StreamBuffer(maxMinutes: 15)
        XCTAssertEqual(buf.currentTimestamp, buf.bufferedDuration)
    }

    // MARK: - WAV header structure

    func testWAVHeader_magic() throws {
        let buf = StreamBuffer(maxMinutes: 5)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        // Give the write queue a moment to open the segment and write the header
        Thread.sleep(forTimeInterval: 0.15)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zappastream_dvr_seg_0.wav").path

        guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
            XCTFail("Segment file not created or too small (path: \(path))")
            return
        }

        // Bytes 0-3: "RIFF"
        XCTAssertEqual(data[0], UInt8(ascii: "R"))
        XCTAssertEqual(data[1], UInt8(ascii: "I"))
        XCTAssertEqual(data[2], UInt8(ascii: "F"))
        XCTAssertEqual(data[3], UInt8(ascii: "F"))

        // Bytes 8-11: "WAVE"
        XCTAssertEqual(data[8],  UInt8(ascii: "W"))
        XCTAssertEqual(data[9],  UInt8(ascii: "A"))
        XCTAssertEqual(data[10], UInt8(ascii: "V"))
        XCTAssertEqual(data[11], UInt8(ascii: "E"))

        // Bytes 12-15: "fmt "
        XCTAssertEqual(data[12], UInt8(ascii: "f"))
        XCTAssertEqual(data[13], UInt8(ascii: "m"))
        XCTAssertEqual(data[14], UInt8(ascii: "t"))
        XCTAssertEqual(data[15], UInt8(ascii: " "))
    }

    func testWAVHeader_PCMFormat() throws {
        let buf = StreamBuffer(maxMinutes: 5)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        Thread.sleep(forTimeInterval: 0.15)

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("zappastream_dvr_seg_0.wav").path

        guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
            XCTFail("Segment file not created or too small")
            return
        }

        // Bytes 20-21: audio format = 1 (PCM), little-endian
        XCTAssertEqual(data[20], 1)
        XCTAssertEqual(data[21], 0)

        // Bytes 22-23: channels = 2, little-endian
        XCTAssertEqual(data[22], 2)
        XCTAssertEqual(data[23], 0)

        // Bytes 24-27: sample rate = 44100 = 0x0000AC44, little-endian
        XCTAssertEqual(data[24], 0x44)
        XCTAssertEqual(data[25], 0xAC)
        XCTAssertEqual(data[26], 0x00)
        XCTAssertEqual(data[27], 0x00)

        // Bytes 34-35: bits per sample = 16, little-endian
        XCTAssertEqual(data[34], 16)
        XCTAssertEqual(data[35], 0)
    }

    // MARK: - updateMaxSegments

    func testUpdateMaxSegments_updatesValue() {
        let buf = StreamBuffer(maxMinutes: 15)
        buf.start()
        defer {
            buf.stop()
            buf.cleanup()
        }

        let expectation = XCTestExpectation(description: "maxSegments updated to 20")
        buf.updateMaxSegments(20)

        // updateMaxSegments dispatches async onto the write queue; wait briefly
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(buf.maxSegments, 20)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }
}
#endif
