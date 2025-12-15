/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RealtimeVoiceService.swift
//
// Minimal integration with OpenAI's Realtime Voice WebSocket API. It connects
// with the provided API key, streams microphone audio, and listens for text
// deltas to show a running transcript. Audio playback is intentionally kept
// out of scope to keep the sample lightweight.
//

import AVFoundation
import Foundation

@MainActor
final class RealtimeVoiceService: NSObject, ObservableObject {
  enum ConnectionState: String {
    case disconnected
    case connecting
    case connected
  }

  @Published var connectionState: ConnectionState = .disconnected
  @Published var transcript: String = ""
  @Published var lastError: String?

  private var webSocketTask: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var audioEngine: AVAudioEngine?
  private var audioConverter: AVAudioConverter?
  private let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16000,
    channels: 1,
    interleaved: true)!

  private let apiKey: String

  init(apiKey: String = OpenAIConfiguration.apiKey) {
    self.apiKey = apiKey
  }

  func connect() {
    guard connectionState == .disconnected else { return }
    guard apiKey.isEmpty == false else {
      lastError = OpenAIClientError.missingAPIKey.localizedDescription
      return
    }

    guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview") else {
      lastError = "Invalid Realtime API URL"
      return
    }

    var request = URLRequest(url: url)
    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

    let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    urlSession = session
    webSocketTask = session.webSocketTask(with: request)
    webSocketTask?.resume()
    connectionState = .connecting
    listenForMessages()
  }

  func disconnect() {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine = nil
    audioConverter = nil

    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    urlSession = nil
    connectionState = .disconnected
  }

  func startVoiceStreaming() {
    guard connectionState == .connected else {
      lastError = "Connect to Realtime first."
      return
    }

    Task { @MainActor [weak self] in
      let permissionGranted = await requestRecordPermission()
      guard permissionGranted else {
        self?.lastError = "Microphone permission is required for Realtime Voice."
        return
      }
      self?.startAudioEngine()
    }
  }

  func sendStarterPrompt(_ text: String) {
    guard connectionState == .connected else { return }
    let message: [String: Any] = [
      "type": "response.create",
      "response": [
        "modalities": ["text", "audio"],
        "instructions": text
      ]
    ]
    send(json: message)
  }

  // MARK: - Private helpers

  private func requestRecordPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func startAudioEngine() {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)
    let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    self.audioConverter = converter

    inputNode.removeTap(onBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self else { return }
      guard let converter else { return }

      let convertedBuffer = AVAudioPCMBuffer(
        pcmFormat: self.targetFormat,
        frameCapacity: AVAudioFrameCount(self.targetFormat.sampleRate) / 4
      )
      var error: NSError?
      let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }
      converter.convert(to: convertedBuffer!, error: &error, withInputFrom: inputBlock)
      if let error {
        DispatchQueue.main.async {
          self.lastError = error.localizedDescription
        }
        return
      }

      if let convertedBuffer, let data = Self.dataFromPCMBuffer(convertedBuffer) {
        self.sendAudioChunk(data)
      }
    }

    do {
      try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
      try AVAudioSession.sharedInstance().setActive(true)
      try engine.start()
      audioEngine = engine
    } catch {
      lastError = error.localizedDescription
    }
  }

  private static func dataFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let channelData = buffer.int16ChannelData else { return nil }
    let frameLength = Int(buffer.frameLength)
    let channelDataPointer = channelData.pointee
    let data = Data(bytes: channelDataPointer, count: frameLength * MemoryLayout<Int16>.size)
    return data
  }

  private func sendAudioChunk(_ data: Data) {
    guard connectionState == .connected else { return }
    let base64Audio = data.base64EncodedString()
    let appendEvent: [String: Any] = [
      "type": "input_audio_buffer.append",
      "audio": base64Audio
    ]
    let commitEvent: [String: Any] = ["type": "input_audio_buffer.commit"]
    let respondEvent: [String: Any] = [
      "type": "response.create",
      "response": [
        "modalities": ["text", "audio"],
        "instructions": "You are connected to Ray-Ban Meta smart glasses. Keep replies concise."
      ]
    ]
    send(json: appendEvent)
    send(json: commitEvent)
    send(json: respondEvent)
  }

  private func listenForMessages() {
    guard let webSocketTask else { return }
    webSocketTask.receive { [weak self] result in
      guard let self else { return }
      switch result {
      case let .success(message):
        switch message {
        case let .string(text):
          self.handleMessage(text)
        case let .data(data):
          if let text = String(data: data, encoding: .utf8) {
            self.handleMessage(text)
          }
        @unknown default:
          break
        }
        self.listenForMessages()
      case let .failure(error):
        DispatchQueue.main.async {
          self.lastError = error.localizedDescription
          self.connectionState = .disconnected
        }
      }
    }
  }

  private func handleMessage(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    guard let type = json["type"] as? String else { return }

    if type == "response.output_text.delta", let delta = json["delta"] as? String {
      transcript.append(contentsOf: delta)
    } else if type == "response.output_text.done" {
      transcript.append("\n")
    }
  }

  private func send(json: [String: Any]) {
    guard let webSocketTask else { return }
    guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
    guard let text = String(data: data, encoding: .utf8) else { return }
    webSocketTask.send(.string(text)) { [weak self] error in
      if let error {
        DispatchQueue.main.async {
          self?.lastError = error.localizedDescription
        }
      }
    }
  }
}

extension RealtimeVoiceService: URLSessionWebSocketDelegate {
  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    Task { @MainActor in
      connectionState = .connected
      sendStarterPrompt("You are connected to Ray-Ban Meta smart glasses.")
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    Task { @MainActor in
      connectionState = .disconnected
    }
  }
}
