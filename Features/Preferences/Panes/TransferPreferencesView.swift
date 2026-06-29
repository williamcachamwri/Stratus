import SwiftUI
import StratusCore

public struct TransferPreferencesView: View {
    @AppStorage("transfer.maxConcurrentFiles") private var maxConcurrentFiles = 4
    @AppStorage("transfer.maxConcurrentChunks") private var maxConcurrentChunks = 32
    @AppStorage("transfer.bandwidthLimitMBPS") private var bandwidthLimitMBPS = 0.0
    @AppStorage("transfer.allowExpensiveNetwork") private var allowExpensiveNetwork = true
    @AppStorage("transfer.allowConstrainedNetwork") private var allowConstrainedNetwork = false

    public init() {}

    public var body: some View {
        Form {
            Section("Parallelism") {
                Stepper("Concurrent files: \(maxConcurrentFiles)", value: $maxConcurrentFiles, in: 1...16)
                Stepper("Global chunk slots: \(maxConcurrentChunks)", value: $maxConcurrentChunks, in: 1...64)
                Text("The scheduler still respects provider caps and congestion feedback.")
                    .stratusCaption()
            }

            Section("Bandwidth") {
                HStack {
                    Slider(value: $bandwidthLimitMBPS, in: 0...500, step: 1)
                    Text(bandwidthTitle)
                        .font(.stratusSmallMono)
                        .frame(width: 96, alignment: .trailing)
                }
                Text("0 means unlimited. Limits are enforced by scheduler delays between chunk uploads.")
                    .stratusCaption()
            }

            Section("Network Policy") {
                Toggle("Allow expensive networks", isOn: $allowExpensiveNetwork)
                Toggle("Allow constrained networks", isOn: $allowConstrainedNetwork)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transfers")
    }

    private var bandwidthTitle: String {
        bandwidthLimitMBPS <= 0 ? "Unlimited" : "\(Int(bandwidthLimitMBPS)) MB/s"
    }
}
