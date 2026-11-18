import SwiftUI

struct ContentView: View {
    @State private var isListening = false

    var body: some View {
        ZStack {
            // content in the background
            Text("Nothing played yet")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)

            VStack {
                Spacer()
                glassBar
                    .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background {
            LinearGradient(
                colors: [.indigo.opacity(0.25), .teal.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    /// floating glass toolbar over the content, per the design rules
    private var glassBar: some View {
        HStack(spacing: 16) {
            Button(isListening ? "Stop listening" : "Start listening") {
                isListening.toggle()
            }
            .glassEffect(isListening ? .regular.tint(.red) : .regular)

            Button("Export MIDI") {}
                .glassEffect()
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
    }
}

#Preview {
    ContentView()
}
