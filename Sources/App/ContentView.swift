import SwiftUI

struct ContentView: View {
    @StateObject private var proxyManager = ProxyManager()
    @State private var vkLink: String = ""
    @State private var peer: String = ""
    @State private var streams: Int = 16
    
    var body: some View {
        VStack(spacing: 16) {
            TextField("VK Link (e.g. https://vk.com/call/join/...)", text: $vkLink)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            
            TextField("Peer Address (e.g. 1.2.3.4:56000)", text: $peer)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            
            Stepper("Streams: \(streams)", value: $streams, in: 1...64)
            
            Button(action: toggleConnection) {
                Text(proxyManager.isRunning ? "Disconnect" : "Connect")
                    .font(.headline)
                    .foregroundColor(proxyManager.isRunning ? .red : .green)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }
            
            Text(proxyManager.statusText)
                .font(.headline)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(proxyManager.logMessages) { log in
                        Text("\(log.timestamp.formatted(date: .omitted, time: .standard)) - \(log.message)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func toggleConnection() {
        if proxyManager.isRunning {
            proxyManager.disconnect()
        } else {
            let config = ProxyConfig(
                peer: peer,
                vkLink: vkLink,
                listen: "127.0.0.1:9000",
                streams: streams,
                udp: false
            )
            proxyManager.connect(config: config)
        }
    }
}
