/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// OpenAIClient.swift
//
// Lightweight helper for calling OpenAI Chat Completions with image input
// and for sharing configuration (API key) between different OpenAI helpers.
//

import Foundation
import UIKit

struct OpenAIConfiguration {
  /// Read the API key from the environment or Info.plist.
  /// Storing the key outside of source control keeps secrets out of git history.
  static var apiKey: String {
    if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], envKey.isEmpty == false {
      return envKey
    }
    if let infoKey = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String, infoKey.isEmpty == false {
      return infoKey
    }
    return ""
  }
}

struct OpenAIChatResponse: Decodable {
  struct Choice: Decodable {
    struct Message: Decodable {
      let content: String
    }
    let message: Message
  }
  let choices: [Choice]
}

enum OpenAIClientError: Error, LocalizedError {
  case missingAPIKey
  case invalidImage
  case badResponse(statusCode: Int)
  case decodeFailure

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Set OPENAI_API_KEY in your environment or Info.plist before calling OpenAI APIs."
    case .invalidImage:
      return "Unable to convert the current frame into an image payload."
    case let .badResponse(statusCode):
      return "OpenAI responded with status code \(statusCode)."
    case .decodeFailure:
      return "Could not decode the response from OpenAI."
    }
  }
}

final class OpenAIClient {
  private let apiKey: String
  private let urlSession: URLSession

  init(apiKey: String = OpenAIConfiguration.apiKey, urlSession: URLSession = .shared) {
    self.apiKey = apiKey
    self.urlSession = urlSession
  }

  /// Sends the provided UIImage to the OpenAI vision-enabled Chat Completions endpoint.
  /// The helper keeps the prompt short so the response feels real-time on device.
  func analyzeImage(prompt: String, image: UIImage) async throws -> String {
    guard apiKey.isEmpty == false else {
      throw OpenAIClientError.missingAPIKey
    }
    guard let jpegData = image.jpegData(compressionQuality: 0.75) else {
      throw OpenAIClientError.invalidImage
    }

    let base64 = jpegData.base64EncodedString()
    let body: [String: Any] = [
      "model": "gpt-4o-mini",
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": prompt],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,\(base64)"]
          ]
        ]
      ]
    ]

    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw OpenAIClientError.badResponse(statusCode: code)
    }

    let decoded = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data)
    guard let message = decoded?.choices.first?.message.content else {
      throw OpenAIClientError.decodeFailure
    }
    return message
  }
}
