import AppKit
import SwiftUI

@main
struct AWDLMonitorApp: App {
    @StateObject private var controller = AWDLController()

    var body: some Scene {
        MenuBarExtra {
            ContentView(controller: controller)
        } label: {
            MenuBarLabel(symbolName: controller.menuBarSymbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarLabel: View {
    let symbolName: String

    var body: some View {
        if let image = MenuBarIcon.image {
            Image(nsImage: image)
                .accessibilityLabel("AWDLmonitor")
        } else {
            Label("AWDLmonitor", systemImage: symbolName)
        }
    }
}

private enum MenuBarIcon {
    static let image: NSImage? = {
        for name in ["menubar-black", "menubar"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MenuBarIcons"),
                  let image = NSImage(contentsOf: url) else {
                continue
            }

            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        return nil
    }()
}

private struct ContentView: View {
    @ObservedObject var controller: AWDLController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AWDLmonitor")
                .font(.headline)

            Text(controller.statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("AWDL off") {
                controller.turnOff()
            }
            .disabled(controller.isBusy)

            Button("AWDL on") {
                controller.turnOn()
            }
            .disabled(controller.isBusy)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}
