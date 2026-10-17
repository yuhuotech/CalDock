import AppKit
import SwiftUI

// A transient SwiftUI popover can dismiss when the system asks for permission.
// Keep this editor attached until Save, Cancel or its parent panel closes.
struct QuickEditorPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.presented = $isPresented
        if isPresented {
            if coordinator.host == nil {
                let host = NSHostingController(rootView: content())
                host.sizingOptions = [.preferredContentSize]
                coordinator.host = host
                coordinator.popover.contentViewController = host
            } else { coordinator.host?.rootView = content() }
            if !coordinator.popover.isShown {
                DispatchQueue.main.async { [weak anchor, weak coordinator] in
                    guard let anchor, anchor.window != nil, let coordinator,
                          coordinator.presented?.wrappedValue == true, !coordinator.popover.isShown else { return }
                    coordinator.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                }
            }
        } else { coordinator.popover.performClose(nil) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.presented = nil
        coordinator.popover.close()
        coordinator.host = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        var host: NSHostingController<Content>?
        var presented: Binding<Bool>?
        override init() {
            super.init()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.delegate = self
        }
        func popoverDidClose(_ notification: Notification) {
            host = nil
            popover.contentViewController = nil
            if presented?.wrappedValue == true { presented?.wrappedValue = false }
        }
        func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    }
}
