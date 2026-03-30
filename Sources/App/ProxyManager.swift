import Foundation
import Combine

/// Log entry with timestamp
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

/// Observable proxy manager for SwiftUI lifecycle
/// Manages proxy connection state and status polling
@MainActor
final class ProxyManager: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "Disconnected"
    @Published private(set) var logMessages: [LogEntry] = []
    
    // MARK: - Private State
    
    private var proxyHandle: Int32 = -1
    private var statusTimer: Timer?
    private let statusQueue = DispatchQueue(label: "com.vkturn.statusQueue", qos: .utility)
    private let maxLogEntries = 100
    
    // MARK: - Configuration
    
    private var currentConfig: ProxyConfig?
    
    // MARK: - Lifecycle
    
    deinit {
        Task { @MainActor in
            if self.isRunning {
                await self.disconnect()
            }
        }
    }
    
    // MARK: - Public API
    
    /// Connect to VK TURN server with given configuration
    /// - Parameter config: Proxy configuration
    func connect(config: ProxyConfig) {
        guard !isRunning else {
            addLog("Already connected")
            return
        }
        
        currentConfig = config
        addLog("Starting proxy connection...")
        statusText = "Connecting..."
        
        // Start proxy on background queue
        Task.detached { [weak self] in
            let handle = VKTurnBridge.startProxy(config: config)
            
            await MainActor.run {
                guard let self = self else { return }
                
                if handle >= 0 {
                    self.proxyHandle = handle
                    self.isRunning = true
                    self.addLog("Proxy started with handle \(handle)")
                    self.startStatusPolling()
                } else {
                    self.addLog("Failed to start proxy: handle returned -1")
                    self.statusText = "Connection Failed"
                }
            }
        }
    }
    
    /// Disconnect from VK TURN server
    @MainActor
    func disconnect() async {
        guard isRunning else {
            addLog("Not connected")
            return
        }
        
        stopStatusPolling()
        
        let handle = proxyHandle
        addLog("Stopping proxy with handle \(handle)...")
        
        // Stop proxy on background queue
        Task.detached { [weak self] in
            VKTurnBridge.stopProxy(handle: handle)
            
            await MainActor.run {
                guard let self = self else { return }
                self.proxyHandle = -1
                self.isRunning = false
                self.statusText = "Disconnected"
                self.addLog("Proxy stopped")
            }
        }
    }
    
    // MARK: - Status Polling
    
    private func startStatusPolling() {
        stopStatusPolling()
        
        // Poll status every second
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.pollStatus()
            }
        }
        
        // Initial poll
        Task {
            await pollStatus()
        }
    }
    
    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    private func pollStatus() async {
        let handle = proxyHandle
        
        // Query status on background queue
        let status: ProxyStatus? = await Task.detached {
            return VKTurnBridge.getStatus(handle: handle)
        }.value
        
        guard let status = status else {
            statusText = "Status Unknown"
            return
        }
        
        // Update UI on main thread
        switch status.state {
        case "running":
            statusText = "Running"
        case "stopped":
            statusText = "Stopped"
            if isRunning {
                addLog("Proxy stopped unexpectedly")
                await disconnect()
            }
        case "error":
            statusText = "Error: \(status.error)"
            if isRunning {
                addLog("Proxy error: \(status.error)")
                await disconnect()
            }
        case "not_found":
            statusText = "Not Found"
            if isRunning {
                addLog("Proxy handle not found")
                await disconnect()
            }
        default:
            statusText = "Unknown State: \(status.state)"
        }
    }
    
    // MARK: - Logging
    
    private func addLog(_ message: String) {
        let entry = LogEntry(timestamp: Date(), message: message)
        logMessages.append(entry)
        
        // Limit log entries to prevent unbounded growth
        if logMessages.count > maxLogEntries {
            logMessages.removeFirst(logMessages.count - maxLogEntries)
        }
    }
    
    // MARK: - Convenience
    
    /// Create default configuration for testing
    static func defaultConfig() -> ProxyConfig {
        ProxyConfig(
            peer: "1.2.3.4:56000",
            vkLink: "https://vk.com/call/join/XXXX",
            listen: "127.0.0.1:9000",
            streams: 16,
            udp: false
        )
    }
}
