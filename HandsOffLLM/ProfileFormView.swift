//
//  ProfileFormView.swift
//  HandsOffLLM
//
//  Created by Eduard Rantsevich on 15.05.25.
//


import SwiftUI
import Speech

struct ProfileFormView: View {
    @EnvironmentObject var settingsService: SettingsService
    @EnvironmentObject var audioService: AudioService
    @Environment(\.dismiss) var dismiss

    let isInitial: Bool

    @State private var selectedLocaleId: String = "en-US"
    @State private var displayName: String = ""
    @State private var profileDescription: String = ""
    @State private var isEditing: Bool = false
    @State private var profileEnabled: Bool = true
    
    private var locales: [Locale] {
        Array(SFSpeechRecognizer.supportedLocales())
            .sorted { lhs, rhs in
                (Locale.current.localizedString(forIdentifier: lhs.identifier) ?? lhs.identifier)
                < (Locale.current.localizedString(forIdentifier: rhs.identifier) ?? rhs.identifier)
            }
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Only show welcome header when in initial setup
                if isInitial {
                    welcomeHeader
                }
                
                // Form Content
                ScrollView {
                    VStack(spacing: 24) {
                        if !isInitial {
                            formField(
                                icon: "person.fill.checkmark",
                                title: "Enable User Profile",
                                subtitle: "Apply these preferences to my conversations",
                                content: {
                                    HStack {
                                        Text("Enable")
                                            .font(.system(size: 17, weight: .medium))
                                            .foregroundColor(Theme.primaryText)
                                        
                                        Spacer()
                                        
                                        Toggle("", isOn: $profileEnabled)
                                            .toggleStyle(SwitchToggleStyle(tint: Theme.accent))
                                            .labelsHidden()
                                            .onChange(of: profileEnabled) { oldValue, newValue in
                                                profileEnabled = newValue
                                            }
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .background(Theme.menuAccent)
                                    .cornerRadius(12)
                                }
                            )
                        }
                        
                        // Name Field
                        formField(
                            icon: "person.fill",
                            title: "Name",
                            subtitle: "How should I address you?",
                            content: {
                                TextField("", text: $displayName)
                                    .placeholder("Alex", when: displayName.isEmpty)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(Theme.primaryText)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .background(Theme.menuAccent)
                                    .cornerRadius(12)
                            }
                        )
                        
                        // Language Selector
                        formField(
                            icon: "globe",
                            title: "Speech Recognition",
                            subtitle: "I'll listen for your voice in this language",
                            content: {
                                VStack(spacing: 8) {
                                    Menu {
                                        ForEach(locales, id: \.identifier) { locale in
                                            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                                            Button(name) {
                                                selectedLocaleId = locale.identifier
                                                isEditing = false
                                            }
                                        }
                                    } label: {
                                        HStack {
                                            Text(Locale.current.localizedString(forIdentifier: selectedLocaleId) ?? selectedLocaleId)
                                                .font(.system(size: 17, weight: .medium))
                                                .foregroundColor(Theme.primaryText)
                                            
                                            Spacer()
                                            
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(Theme.secondaryText)
                                        }
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                        .background(Theme.menuAccent)
                                        .cornerRadius(12)
                                    }
                                    
                                    HStack {
                                        Image(systemName: "info.circle")
                                            .font(.system(size: 12))
                                            .foregroundColor(Theme.accent.opacity(0.8))
                                        
                                        Text("I can respond in any language - just ask!")
                                            .font(.system(size: 14))
                                            .foregroundColor(Theme.secondaryText)
                                        
                                        Spacer()
                                    }
                                    .padding(.horizontal, 4)
                                }
                            }
                        )
                        
                        // Bio Field
                        formField(
                            icon: "text.bubble.fill",
                            title: "About You",
                            subtitle: "Share anything that helps me assist you better",
                            content: {
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $profileDescription)
                                        .font(.system(size: 17))
                                        .foregroundColor(Theme.primaryText)
                                        .frame(minHeight: 100)
                                        .scrollContentBackground(.hidden)
                                        .background(Theme.menuAccent)
                                        .cornerRadius(12)
                                        .padding(.top, isEditing ? 8 : 0)
                                    
                                    if profileDescription.isEmpty && !isEditing {
                                        Text("I enjoy cooking and hiking on weekends. I'm interested in science and tech news. I prefer responses in German.")
                                            .font(.system(size: 17))
                                            .foregroundColor(Theme.secondaryText.opacity(0.6))
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 16)
                                    }
                                }
                                .onTapGesture {
                                    isEditing = true
                                }
                            }
                        )
                        
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, isInitial ? 0 : 20)
                }
                
                // Bottom Action Buttons
                bottomActionBar
            }
        }
        // Hide navigation bar completely in initial setup
        .navigationBarHidden(isInitial)
        // For non-initial mode, show title
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(isInitial ? "" : "Your Profile")
        .toolbar {
            if !isInitial {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        finish()
                        dismiss()
                    }
                    .foregroundColor(Theme.accent)
                }
            }
        }
        .onAppear {
            selectedLocaleId = settingsService.settings.speechRecognitionLanguage ?? "en-US"
            displayName = settingsService.settings.userDisplayName ?? ""
            profileDescription = settingsService.settings.userProfileDescription ?? ""
            profileEnabled = settingsService.settings.userProfileEnabled
        }
        .onTapGesture {
            isEditing = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    
    // MARK: - Component Views
    
    private var welcomeHeader: some View {
        VStack(spacing: 12) {
            Text("Welcome to HandsOffLLM")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 40)
            
            Text("Tell me a bit about yourself")
                .font(.system(size: 17))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 30)
        }
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private func formField<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 24, height: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Theme.primaryText)
                    
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.secondaryText)
                }
            }
            
            content()
        }
        .opacity(!isInitial && !profileEnabled ? 0.6 : 1.0)
    }
    
    private var bottomActionBar: some View {
        Group {
            if isInitial {
                HStack(spacing: 16) {
                    Button {
                        finish()
                    } label: {
                        Text(displayName.isEmpty ? "Skip" : "Continue")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.accent)
                            .cornerRadius(16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .background(
                    Theme.background
                        .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: -5)
                )
            }
        }
    }
    
    // MARK: - Action Methods
    
    private func finish() {
        // 1) Remember old language so we can compare after saving
        let oldLocale = settingsService.settings.speechRecognitionLanguage
        
        // 2) Atomically update & save once
        settingsService.updateUserProfile(
            language: selectedLocaleId,
            displayName: displayName,
            description: profileDescription,
            enabled: profileEnabled,
            completedInitialSetup: isInitial
        )
        
        // 3) Only re‐initialize speech recognizer if the language actually changed
        if oldLocale != selectedLocaleId {
            audioService.updateSpeechRecognizerLocale(selectedLocaleId)
        }

        // 4) Dismiss when called from Settings (not on initial setup)
        if !isInitial {
            dismiss()
        }
    }
}

// MARK: - Placeholder Extension

extension View {
    func placeholder<Content: View>(
        _ text: String,
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {
        
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
    
    func placeholder(_ text: String, when shouldShow: Bool) -> some View {
        self.placeholder(text, when: shouldShow, placeholder: {
            Text(text)
                .foregroundColor(Theme.secondaryText.opacity(0.6))
                .padding(.leading, 4)
        })
    }
}

struct ProfileFormView_Previews: PreviewProvider {
    static var previews: some View {
        let settings = SettingsService()
        let audio = AudioService(settingsService: settings, historyService: HistoryService())
        return ProfileFormView(isInitial: true)
            .environmentObject(settings)
            .environmentObject(audio)
            .preferredColorScheme(.dark)
    }
}