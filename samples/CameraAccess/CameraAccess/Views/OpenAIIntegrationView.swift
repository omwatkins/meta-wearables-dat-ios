/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// OpenAIIntegrationView.swift
//
// Presents controls for vision analysis and Realtime Voice streaming.
// The view assumes an API key is supplied via OPENAI_API_KEY in the build
// environment or Info.plist.
//

import SwiftUI

struct OpenAIIntegrationView: View {
  @ObservedObject var streamViewModel: StreamSessionViewModel
  @ObservedObject var aiViewModel: OpenAIIntegrationViewModel

  var body: some View {
    NavigationView {
      Form {
        visionSection
        realtimeVoiceSection
        helpSection
      }
      .navigationTitle("OpenAI Assist")
      .alert("Error", isPresented: Binding(
        get: { aiViewModel.lastError != nil },
        set: { _ in aiViewModel.lastError = nil }
      )) {
        Button("OK", role: .cancel) { aiViewModel.lastError = nil }
      } message: {
        Text(aiViewModel.lastError ?? "")
      }
    }
  }

  private var visionSection: some View {
    Section(header: Text("Vision")) {
      TextField("Prompt", text: $aiViewModel.visionPrompt)

      Button {
        Task { await aiViewModel.analyze(image: streamViewModel.currentVideoFrame) }
      } label: {
        if aiViewModel.isAnalyzing {
          ProgressView()
        } else {
          Text("Analyze current frame")
        }
      }
      .disabled(streamViewModel.currentVideoFrame == nil || aiViewModel.isAnalyzing)

      if aiViewModel.visionResponse.isEmpty == false {
        Text(aiViewModel.visionResponse)
          .font(.callout)
      }
    }
  }

  private var realtimeVoiceSection: some View {
    Section(header: Text("Realtime voice")) {
      HStack {
        Text("Status")
        Spacer()
        Text(aiViewModel.voiceState.rawValue.capitalized)
          .foregroundStyle(.secondary)
      }

      Button(aiViewModel.voiceState == .disconnected ? "Connect" : "Disconnect") {
        if aiViewModel.voiceState == .disconnected {
          aiViewModel.connectRealtimeVoice()
        } else {
          aiViewModel.disconnectRealtimeVoice()
        }
      }

      Button("Start microphone streaming") {
        aiViewModel.startVoiceStreaming()
      }
      .disabled(aiViewModel.voiceState != .connected)

      if aiViewModel.voiceTranscript.isEmpty == false {
        Text(aiViewModel.voiceTranscript)
          .font(.callout)
      } else {
        Text("Transcript will appear here once you speak.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var helpSection: some View {
    Section(header: Text("API key")) {
      Text("Set OPENAI_API_KEY in your environment or Info.plist to connect to OpenAI.")
        .font(.callout)
    }
  }
}
