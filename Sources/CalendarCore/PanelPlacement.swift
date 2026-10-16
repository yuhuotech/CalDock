import Foundation
import CoreGraphics

public enum PanelPlacement {
    public static func frame(content: CGSize, screen: CGRect, anchor: CGRect?, menuHeight: Double) -> CGRect {
        let margin = 8.0
        let width = min(content.width, max(1, screen.width - margin * 2))
        let height = min(content.height, max(1, screen.height - menuHeight - margin * 2))
        let x = min(max(screen.minX + margin, (anchor?.midX ?? screen.maxX - width / 2 - 12) - width / 2), screen.maxX - width - margin)
        let top = min(anchor?.minY ?? screen.maxY - menuHeight, screen.maxY - menuHeight)
        let y = max(screen.minY + margin, top - height - 5)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
