import CoreGraphics

enum DockVisibility {
    static func screenHasVisibleDockReservedArea(
        screenFrame: CGRect,
        visibleFrame: CGRect
    ) -> Bool {
        visibleFrame.minX > screenFrame.minX ||
        visibleFrame.minY > screenFrame.minY ||
        visibleFrame.maxX < screenFrame.maxX
    }

    static func shouldShowCharacters(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        isMainScreen: Bool,
        dockAutohideEnabled: Bool
    ) -> Bool {
        if screenHasVisibleDockReservedArea(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ) {
            return true
        }

        let menuBarVisible = visibleFrame.maxY < screenFrame.maxY
        return dockAutohideEnabled && isMainScreen && menuBarVisible
    }
}
