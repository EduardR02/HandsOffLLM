import SwiftUI

struct AuthView: View {
    @StateObject private var authService = AuthService.shared
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 30) {
            Spacer()

            // App Logo/Title
            VStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.blue.gradient)

                Text("HandsOffLLM")
                    .font(.largeTitle)
                    .fontWeight(.bold)
            }

            Spacer()

            // Auth explanation
            VStack(spacing: 12) {
                Text("Sign in to continue")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("We use authentication to track your usage and prevent abuse. Your conversations stay on your device.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Sign-in buttons
            VStack(spacing: 16) {
                // Google Sign-In Button
                Button(action: {
                    signInWithGoogle()
                }) {
                    HStack {
                        Image(systemName: "g.circle.fill")
                            .font(.system(size: 20))
                        Text("Continue with Google")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
                .disabled(isLoading)
            }
            .padding(.horizontal, 40)

            // Error message
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            // Privacy note
            Text("By continuing, you agree to our Terms of Service and Privacy Policy")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        }
    }

    private func signInWithApple() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.signInWithApple()
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func signInWithGoogle() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                try await authService.signInWithGoogle()
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    AuthView()
}
