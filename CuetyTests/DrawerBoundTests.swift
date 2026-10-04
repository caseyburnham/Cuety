import SwiftUI
import Testing

@testable import Cuety

@Suite("Drawer height bound")
@MainActor
struct DrawerBoundTests {
    private static let windowHeight: CGFloat = 560

    @Test("The window's share never leaves the display the smaller half")
    func shareFavoursTheDisplay() {
        let detailHeight = Self.windowHeight
        let drawerBound = detailHeight * CueDrawerView.maxHeightShare

        #expect(drawerBound <= detailHeight / 2)
        #expect(drawerBound > CueRowView.Role.largestRowFontSize * 6)
    }

    @Test("A taller window snaps to more rows, up to the preference's limit")
    func stepsFollowTheAvailableHeight() {
        #expect(
            CueDrawerView.stepsFitting(Self.windowHeight)
                < CueDrawerView.stepsFitting(Self.windowHeight * 2)
        )
        #expect(CueDrawerView.stepsFitting(4_000) == Preferences.Limits.drawerRows.upperBound)
        #expect(CueDrawerView.stepsFitting(120) == Preferences.Limits.drawerRows.lowerBound)
    }

    @Test("The step a window snaps to keeps the drawer inside its share")
    func fittedStepsStayInsideTheShare() {
        for height in stride(from: 400.0, through: 1_600.0, by: 100) {
            let step = CueDrawerView.stepsFitting(height)
            #expect(
                CueDrawerView.height(atStep: step)
                    <= height * CueDrawerView.maxHeightShare
            )

            let nextStep = step + 1
            if nextStep <= Preferences.Limits.drawerRows.upperBound {
                #expect(
                    CueDrawerView.height(atStep: nextStep)
                        > height * CueDrawerView.maxHeightShare
                )
            }
        }
    }
}
