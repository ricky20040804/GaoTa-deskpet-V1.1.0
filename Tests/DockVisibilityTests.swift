import Foundation
import CoreGraphics

func runDockVisibilityTests() {
    func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    expect(
        DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 64, width: 1440, height: 811),
            isMainScreen: true,
            dockAutohideEnabled: false
        ),
        "shows characters when the bottom dock reserves screen space"
    )

    expect(
        DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: CGRect(x: 96, y: 0, width: 1344, height: 875),
            isMainScreen: true,
            dockAutohideEnabled: false
        ),
        "shows characters when the dock is pinned to the left edge"
    )

    expect(
        DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1344, height: 875),
            isMainScreen: true,
            dockAutohideEnabled: false
        ),
        "shows characters when the dock is pinned to the right edge"
    )

    expect(
        !DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: screenFrame,
            isMainScreen: true,
            dockAutohideEnabled: false
        ),
        "hides characters in fullscreen spaces where neither dock nor menu bar is visible"
    )

    expect(
        DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            isMainScreen: true,
            dockAutohideEnabled: true
        ),
        "shows characters on the main screen when the dock auto-hides but the menu bar is visible"
    )

    expect(
        !DockVisibility.shouldShowCharacters(
            screenFrame: screenFrame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            isMainScreen: false,
            dockAutohideEnabled: true
        ),
        "keeps characters hidden on non-main screens when only the menu bar is visible"
    )

    print("DockVisibility tests passed")
}
