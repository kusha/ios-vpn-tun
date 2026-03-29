import AVFoundation
import Foundation

/// Background audio mode manager for keeping VK Turn Proxy app alive
/// 
/// This utility class uses the iOS background audio trick: by configuring AVAudioSession
/// with `.playback` category and playing silent audio in a loop, we keep the app alive
/// when the user switches to other apps (like WireGuard). iOS is still likely to kill the
/// app eventually, but this extends the background lifetime significantly.
/// 
/// Usage:
///   let bgAudio = BackgroundAudioManager()
///   bgAudio.startBackgroundAudio()   // Start when proxy starts
///   bgAudio.stopBackgroundAudio()    // Stop when proxy stops
/// 
/// Note: This is optional for proxy functionality — the proxy works fine in foreground.
/// Background mode is a convenience feature.
final class BackgroundAudioManager {
    
    // MARK: - Properties
    
    private var audioPlayer: AVAudioPlayer?
    private let audioSession = AVAudioSession.sharedInstance()
    private var isRunning = false
    
    // MARK: - Public Methods
    
    /// Start playing silent audio loop to keep app alive in background
    /// 
    /// Configures AVAudioSession for playback and starts an infinite loop
    /// of silence. Safe to call multiple times (no-op if already running).
    func startBackgroundAudio() {
        guard !isRunning else { return }
        
        do {
            // Configure audio session for playback
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Generate 1 second of silence
            guard let silenceData = generateSilence() else {
                print("[BackgroundAudio] Failed to generate silence")
                return
            }
            
            // Create audio player with silence data
            audioPlayer = try AVAudioPlayer(data: silenceData, fileTypeHint: .wav)
            
            guard let audioPlayer = audioPlayer else {
                print("[BackgroundAudio] Failed to create audio player")
                return
            }
            
            // Configure infinite loop
            audioPlayer.numberOfLoops = -1  // -1 = infinite loop
            audioPlayer.volume = 0.0  // Silent
            
            // Start playback
            guard audioPlayer.play() else {
                print("[BackgroundAudio] Failed to start audio playback")
                audioPlayer.stop()
                return
            }
            
            isRunning = true
            print("[BackgroundAudio] Started background audio loop")
            
        } catch {
            print("[BackgroundAudio] Error starting background audio: \(error)")
            // Graceful failure - proxy still works without background audio
        }
    }
    
    /// Stop playing background audio and deactivate audio session
    /// 
    /// Safe to call multiple times (no-op if not running).
    func stopBackgroundAudio() {
        guard isRunning else { return }
        
        do {
            audioPlayer?.stop()
            audioPlayer = nil
            
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            isRunning = false
            print("[BackgroundAudio] Stopped background audio")
            
        } catch {
            print("[BackgroundAudio] Error stopping background audio: \(error)")
        }
    }
    
    // MARK: - Private Methods
    
    /// Generate 1 second of silence as WAV audio data
    /// 
    /// Creates a 44.1kHz mono audio buffer filled with zeros (silence),
    /// then exports it as WAV format for use with AVAudioPlayer.
    /// 
    /// Returns: WAV audio data, or nil if generation fails
    private func generateSilence() -> Data? {
        let sampleRate: Float = 44100.0
        let channels: UInt32 = 1
        let durationSeconds = 1.0
        let frameCount = UInt32(sampleRate * Float(durationSeconds))
        
        // Create audio format
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: channels,
            interleaved: true
        ) else {
            print("[BackgroundAudio] Failed to create audio format")
            return nil
        }
        
        // Create PCM buffer (filled with zeros by default)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            print("[BackgroundAudio] Failed to create audio buffer")
            return nil
        }
        
        buffer.frameLength = frameCount
        
        // Buffer is already zeroed (silence), so we just export it to WAV
        return audioBufferToWAV(buffer: buffer)
    }
    
    /// Convert AVAudioPCMBuffer to WAV format Data
    /// 
    /// Creates a minimal WAV file header and appends the PCM audio data.
    /// This is a simplified WAV encoder suitable for simple audio generation.
    private func audioBufferToWAV(buffer: AVAudioPCMBuffer) -> Data {
        var wavData = Data()
        let pcmFormat = buffer.format
        let frameLength = Int(buffer.frameLength)
        
        // Get PCM data (int16)
        guard let int16Data = buffer.int16ChannelData?[0] else {
            print("[BackgroundAudio] Failed to get PCM data")
            return Data()
        }
        
        let pcmData = Data(bytes: int16Data, count: frameLength * 2)  // 2 bytes per int16 sample
        
        // WAV header parameters
        let sampleRate = UInt32(pcmFormat.sampleRate)
        let channels = UInt16(pcmFormat.channelCount)
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        let audioDataSize = UInt32(pcmData.count)
        let fileSize = UInt32(36 + audioDataSize)
        
        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        appendUInt32LittleEndian(&wavData, fileSize)
        wavData.append(contentsOf: "WAVE".utf8)
        
        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        appendUInt32LittleEndian(&wavData, 16)  // subchunk1Size
        appendUInt16LittleEndian(&wavData, 1)   // audioFormat (PCM)
        appendUInt16LittleEndian(&wavData, channels)
        appendUInt32LittleEndian(&wavData, sampleRate)
        appendUInt32LittleEndian(&wavData, byteRate)
        appendUInt16LittleEndian(&wavData, blockAlign)
        appendUInt16LittleEndian(&wavData, 16)  // bitsPerSample
        
        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        appendUInt32LittleEndian(&wavData, audioDataSize)
        wavData.append(pcmData)
        
        return wavData
    }
    
    /// Helper: Append UInt32 in little-endian format
    private func appendUInt32LittleEndian(_ data: inout Data, _ value: UInt32) {
        var val = value
        data.append(UnsafeBufferPointer(start: &val, count: 1))
    }
    
    /// Helper: Append UInt16 in little-endian format
    private func appendUInt16LittleEndian(_ data: inout Data, _ value: UInt16) {
        var val = value
        data.append(UnsafeBufferPointer(start: &val, count: 1))
    }
}
