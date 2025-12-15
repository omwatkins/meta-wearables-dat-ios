/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// OpenAIIntegrationViewModel.swift
//
// Bridges the CameraAccess sample with OpenAI's vision and Realtime Voice APIs.
// Handles frame analysis, microphone streaming, and exposes user-friendly
// state for SwiftUI views.
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class OpenAIIntegrationViewModel: ObservableObject {
  @Published var visionPrompt: String = "What am I looking at?"
  @Published var visionResponse: String = ""
  @Published var isAnalyzing: Bool = false

  @Published var voiceTranscript: String = ""
  @Published var voiceState: RealtimeVoiceService.ConnectionState = .disconnected
  @Published var lastError: String?

  private let client: OpenAIClient
  private let realtimeVoiceService: RealtimeVoiceService

  init(
    client: OpenAIClient = OpenAIClient(),
    realtimeVoiceService: RealtimeVoiceService = RealtimeVoiceService()
  ) {
    self.client = client
    self.realtimeVoiceService = realtimeVoiceService

    realtimeVoiceService.$transcript
      .receive(on: RunLoop.main)
      .assign(to: &self.$voiceTranscript)

    realtimeVoiceService.$connectionState
      .receive(on: RunLoop.main)
      .assign(to: &self.$voiceState)

    realtimeVoiceService.$lastError
      .receive(on: RunLoop.main)
      .assign(to: &self.$lastError)
  }

  func analyze(image: UIImage?) async {
    guard let image else {
      lastError = OpenAIClientError.invalidImage.localizedDescription
      return
    }
    guard isAnalyzing == false else { return }
    isAnalyzing = true
    defer { isAnalyzing = false }

    do {
      let result = try await client.analyzeImage(prompt: visionPrompt, image: image)
      visionResponse = result
    } catch {
      lastError = error.localizedDescription
    }
  }

  func connectRealtimeVoice() {
    realtimeVoiceService.connect()
  }

  func disconnectRealtimeVoice() {
    realtimeVoiceService.disconnect()
  }

  func startVoiceStreaming() {
    realtimeVoiceService.startVoiceStreaming()
  }
}
