//  Prompts.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 09.04.25.


import Foundation

struct Prompts {
    // remove the "-template" from the filename to use it
    // Define your default system prompt here
    static let chatPrompt: String? = "You are a helpful voice assistant. Keep your responses concise and conversational."
    static let ttsInstructions: String? = "Speak in a clear and natural voice."
}
