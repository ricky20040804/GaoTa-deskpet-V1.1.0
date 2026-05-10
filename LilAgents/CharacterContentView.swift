import AppKit

class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class CharacterContentView: NSView {
    weak var character: WalkerCharacter?
    private let spriteLayer = CALayer()
    private var spritesheet: CGImage?
    private var actionSheets: [Int: CGImage] = [:]
    private var frameCache: [String: CGImage] = [:]
    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var didDragWindow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        spriteLayer.contentsGravity = .resize
        spriteLayer.frame = bounds
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .linear
        layer?.addSublayer(spriteLayer)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.frame = bounds
        CATransaction.commit()
    }

    func loadPet(_ package: PetPackage) {
        spritesheet = nil
        actionSheets.removeAll()
        frameCache.removeAll()

        if !package.actionSheetURLs.isEmpty {
            for (row, url) in package.actionSheetURLs {
                guard let image = NSImage(contentsOf: url),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    print("Action sheet not found or unreadable: \(url.path)")
                    continue
                }
                actionSheets[row] = cgImage
            }
        }

        if actionSheets.isEmpty {
            guard let spritesheetURL = package.spritesheetURL,
                  let image = NSImage(contentsOf: spritesheetURL),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("Pet art not found or unreadable: \(package.displayName)")
                return
            }
            spritesheet = cgImage
        }

        showFrame(row: 0, column: 0)
    }

    func showFrame(row: Int, column: Int, flipped: Bool = false) {
        let boundedRow = min(max(row, 0), PetAnimationPlayer.rows - 1)
        let boundedColumn = min(max(column, 0), PetAnimationPlayer.columns - 1)
        let cacheKey = "\(boundedRow):\(boundedColumn):\(flipped ? 1 : 0)"

        let frameImage: CGImage?
        if let cached = frameCache[cacheKey] {
            frameImage = cached
        } else {
            let source = actionSheets[boundedRow] ?? spritesheet
            guard let source else { return }
            let y = actionSheets[boundedRow] == nil ? CGFloat(boundedRow) * PetAnimationPlayer.frameHeight : 0
            let rect = CGRect(
                x: CGFloat(boundedColumn) * PetAnimationPlayer.frameWidth,
                y: y,
                width: PetAnimationPlayer.frameWidth,
                height: PetAnimationPlayer.frameHeight
            )
            if let cropped = source.cropping(to: rect), flipped {
                let image = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
                let flippedImage = NSImage(size: image.size)
                flippedImage.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .none
                let transform = NSAffineTransform()
                transform.translateX(by: image.size.width, yBy: 0)
                transform.scaleX(by: -1, yBy: 1)
                transform.concat()
                image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
                flippedImage.unlockFocus()
                frameImage = flippedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            } else {
                frameImage = source.cropping(to: rect)
            }
            if let frameImage {
                frameCache[cacheKey] = frameImage
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = frameImage
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }

        let screenPoint = window?.convertPoint(toScreen: convert(localPoint, to: nil)) ?? .zero
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let flippedY = primaryScreen.frame.height - screenPoint.y

        let captureRect = CGRect(x: screenPoint.x - 0.5, y: flippedY - 0.5, width: 1, height: 1)
        guard let windowID = window?.windowNumber, windowID > 0 else { return nil }

        if let image = CGWindowListCreateImage(
            captureRect,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixel: [UInt8] = [0, 0, 0, 0]
            if let ctx = CGContext(
                data: &pixel, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if pixel[3] > 30 {
                    return self
                }
                return nil
            }
        }

        // Fallback: accept click if within center 60% of the view
        let insetX = bounds.width * 0.2
        let insetY = bounds.height * 0.15
        let hitRect = bounds.insetBy(dx: insetX, dy: insetY)
        return hitRect.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        didDragWindow = false
        character?.beginUserDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint = dragStartScreenPoint,
              let startOrigin = dragStartWindowOrigin else { return }

        let currentPoint = NSEvent.mouseLocation
        let dx = currentPoint.x - startPoint.x
        let dy = currentPoint.y - startPoint.y

        if !didDragWindow, hypot(dx, dy) < 3 {
            return
        }

        didDragWindow = true
        let newOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        character?.dragWindow(to: newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartScreenPoint = nil
            dragStartWindowOrigin = nil
        }

        if didDragWindow {
            character?.endUserDrag()
        } else {
            character?.cancelUserDrag()
            character?.handleClick()
        }
    }
}
