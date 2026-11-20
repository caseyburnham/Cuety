import CoreGraphics
import Testing

@testable import Cuety

@Suite("Cue drum resizing")
@MainActor
struct CueDrumResizeTests {
    @Test("Crossing row thresholds never takes height away from standby")
    func continuousResize() {
        var previousBand = DrumMetrics.bandHeight(for: 200)
        var previousStandby = CGFloat(200) - previousBand * 2
        for pixel in 801...4800 {
            let height = CGFloat(pixel) / 4
            let band = DrumMetrics.bandHeight(for: height)
            let standby = height - band * 2
            #expect(band >= previousBand)
            #expect(band - previousBand <= 0.25)
            #expect(standby >= previousStandby)
            previousBand = band
            previousStandby = standby
        }
    }

    @Test("Outer cues cross the window edge continuously")
    func edgeReveal() {
        func metrics(height: CGFloat) -> DrumMetrics {
            DrumMetrics(
                size: CGSize(width: 900, height: height),
                bandHeight: DrumMetrics.bandHeight(for: height),
                standbyNumberSize: 150, standbyNameSize: 28,
                showsStandbyName: true, numberCenterY: height / 2,
                arrowSize: 45, arrowX: 200, pillsTop: height / 2 + 100
            )
        }
        let before = metrics(height: 443.9)
        let after = metrics(height: 444.1)
        #expect(before.y(at: -3) < 0)
        #expect(after.y(at: -3) > 0)
        #expect(after.y(at: -3) - before.y(at: -3) < 0.1)
        #expect(before.opacity(at: -3) == after.opacity(at: -3))
        #expect(before.lastPosition == after.lastPosition)
    }
}
