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

    @Test("Larger upcoming cue presets scale upcoming rows and bottom band while preserving standby growth")
    func upcomingCueSizeScaling() {
        for size in UpcomingCueSize.allCases {
            var previousTop = DrumMetrics.bandHeight(for: 200)
            var previousBottom = DrumMetrics.bandHeight(for: 200, scale: size.scale)
            var previousStandby = CGFloat(200) - previousTop - previousBottom
            for pixel in 801...4800 {
                let height = CGFloat(pixel) / 4
                let top = DrumMetrics.bandHeight(for: height)
                let bottom = DrumMetrics.bandHeight(for: height, scale: size.scale)
                let standby = height - top - bottom
                #expect(bottom >= previousBottom)
                #expect(standby >= previousStandby)
                previousTop = top
                previousBottom = bottom
                previousStandby = standby
            }
        }

        let regular = DrumMetrics(
            size: CGSize(width: 900, height: 800),
            bandHeight: DrumMetrics.bandHeight(for: 800),
            bottomBandHeight: DrumMetrics.bandHeight(for: 800, scale: UpcomingCueSize.regular.scale),
            upcomingScale: UpcomingCueSize.regular.scale,
            standbyNumberSize: 150, standbyNameSize: 28,
            showsStandbyName: true, numberCenterY: 400,
            arrowSize: 45, arrowX: 200, pillsTop: 500
        )
        let extraLarge = DrumMetrics(
            size: CGSize(width: 900, height: 800),
            bandHeight: DrumMetrics.bandHeight(for: 800),
            bottomBandHeight: DrumMetrics.bandHeight(for: 800, scale: UpcomingCueSize.extraLarge.scale),
            upcomingScale: UpcomingCueSize.extraLarge.scale,
            standbyNumberSize: 150, standbyNameSize: 28,
            showsStandbyName: true, numberCenterY: 400,
            arrowSize: 45, arrowX: 200, pillsTop: 500
        )

        // Previous cues above the playhead remain at the compact default size and pitch.
        #expect(extraLarge.numberSize(at: -1) == regular.numberSize(at: -1))
        #expect(extraLarge.nameSize(at: -1) == regular.nameSize(at: -1))
        #expect(extraLarge.y(at: -1) == regular.y(at: -1))

        // Upcoming cues below the playhead scale up in font size and row spacing.
        #expect(extraLarge.numberSize(at: 1) == regular.numberSize(at: 1) * UpcomingCueSize.extraLarge.scale)
        #expect(extraLarge.nameSize(at: 1) == regular.nameSize(at: 1) * UpcomingCueSize.extraLarge.scale)
        #expect((extraLarge.y(at: 2) - extraLarge.y(at: 1)) == (regular.y(at: 2) - regular.y(at: 1)) * UpcomingCueSize.extraLarge.scale)
    }
}
