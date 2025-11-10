import Foundation
import OSLog
import Supabase
import AuthenticationServices
import GoogleSignIn

enum AuthState {
    case authenticated
    case unauthenticated
}

@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "AuthService")

    // Optimistic: assume authenticated, only switch to unauthenticated if check fails
    @Published var authState: AuthState = .authenticated
    @Published var currentUser: User?
    @Published var session: Session?

    // Computed property for backward compatibility
    var isAuthenticated: Bool {
        authState == .authenticated
    }

    // Cleanup callback for when auth fails after app has started
    var onAuthenticationFailed: (() -> Void)?

    // Track initial session check to prevent race conditions
    private var initialSessionCheck: Task<Void, Never>?

    // Track in-flight token refresh to prevent duplicate requests
    private var refreshTask: Task<Void, Error>?

    let supabase: SupabaseClient

    private init() {
        guard let supabaseURL = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let supabaseAnonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              let googleClientID = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_IOS_CLIENT_ID") as? String else {
            fatalError("Missing Supabase or Google credentials in Info.plist")
        }

        let supabaseOptions = SupabaseClientOptions(
            auth: .init(emitLocalSessionAsInitialSession: true)
        )

        self.supabase = SupabaseClient(
            supabaseURL: URL(string: supabaseURL)!,
            supabaseKey: supabaseAnonKey,
            options: supabaseOptions
        )

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: googleClientID)

        // Check for existing session and track it
        initialSessionCheck = Task {
            await checkSession()
        }
    }

    func checkSession() async {
        do {
            let session = try await supabase.auth.session
            self.session = session
            self.currentUser = session.user

            // Only update state if it changed (prevents unnecessary view updates)
            if authState != .authenticated {
                self.authState = .authenticated
            }

            logger.info("Existing session found for user: \(session.user.id)")
        } catch {
            logger.info("No existing session found")

            // Only update state if it changed
            if authState != .unauthenticated {
                self.authState = .unauthenticated
            }

            self.currentUser = nil
            self.session = nil

            // Trigger cleanup if app has already started
            onAuthenticationFailed?()
        }
    }

    func signInWithApple() async throws {
        logger.info("Apple Sign-In initiated")

        return try await withCheckedThrowingContinuation { continuation in
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]

            let controller = ASAuthorizationController(authorizationRequests: [request])

            let delegate = AppleSignInDelegate { result in
                switch result {
                case .success(let credential):
                    Task { @MainActor [weak self] in
                        guard let self = self else {
                            continuation.resume(throwing: AuthError.cancelled)
                            return
                        }

                        do {
                            guard let idToken = credential.identityToken,
                                  let idTokenString = String(data: idToken, encoding: .utf8) else {
                                throw AuthError.invalidCredential
                            }

                            try await self.supabase.auth.signInWithIdToken(
                                credentials: .init(
                                    provider: .apple,
                                    idToken: idTokenString
                                )
                            )

                            // Extract session directly (already validated by signInWithIdToken)
                            let session = try await self.supabase.auth.session
                            self.session = session
                            self.currentUser = session.user
                            if self.authState != .authenticated {
                                self.authState = .authenticated
                            }

                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            controller.delegate = delegate
            controller.performRequests()
        }
    }

    func signInWithGoogle() async throws {
        logger.info("Google Sign-In initiated")

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw AuthError.noViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.invalidCredential
        }

        try await supabase.auth.signInWithIdToken(
            credentials: .init(
                provider: .google,
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        )

        // Extract session directly (already validated by signInWithIdToken)
        let session = try await supabase.auth.session
        self.session = session
        self.currentUser = session.user
        if authState != .authenticated {
            self.authState = .authenticated
        }

        logger.info("Google Sign-In completed successfully")
    }

    func signOut() async throws {
        try await supabase.auth.signOut()
        self.authState = .unauthenticated
        self.currentUser = nil
        self.session = nil
        logger.info("User signed out successfully")
    }

    func getCurrentJWT() async throws -> String {
        // Wait for initial session check to complete (prevents race condition on cold start)
        await initialSessionCheck?.value

        guard let session = session else {
            throw NSError(domain: "AuthService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No active session"
            ])
        }

        // Check if token is expired or close to expiring (within 5 minutes)
        let expiresAt = session.expiresAt
        let now = Date().timeIntervalSince1970
        let fiveMinutes: TimeInterval = 5 * 60

        if expiresAt - now < fiveMinutes {
            logger.info("JWT token expiring soon, refreshing session")
            do {
                try await refreshSession()
                return self.session?.accessToken ?? session.accessToken
            } catch {
                logger.error("Failed to refresh session: \(error.localizedDescription)")

                // Refresh failed - likely both tokens expired, redirect to login
                if authState != .unauthenticated {
                    self.authState = .unauthenticated
                    self.currentUser = nil
                    self.session = nil
                    onAuthenticationFailed?()
                }

                throw error
            }
        }

        return session.accessToken
    }

    func refreshSession() async throws {
        // If refresh is already in progress, wait for it instead of starting a new one
        if let existingRefresh = refreshTask {
            logger.info("Refresh already in progress, waiting for it to complete")
            try await existingRefresh.value
            return
        }

        // Start new refresh task
        let task = Task<Void, Error> {
            logger.info("Refreshing session")
            let newSession = try await supabase.auth.refreshSession()
            self.session = newSession
            self.currentUser = newSession.user
            if self.authState != .authenticated {
                self.authState = .authenticated
            }
            logger.info("Session refreshed successfully")
        }

        refreshTask = task

        do {
            try await task.value
        } catch {
            throw error
        }

        // Clear task after completion
        refreshTask = nil
    }
}

// MARK: - Apple Sign-In Delegate
private class AppleSignInDelegate: NSObject, ASAuthorizationControllerDelegate {
    private let completion: (Result<ASAuthorizationAppleIDCredential, Error>) -> Void

    init(completion: @escaping (Result<ASAuthorizationAppleIDCredential, Error>) -> Void) {
        self.completion = completion
        super.init()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            completion(.failure(AuthError.invalidCredential))
            return
        }
        completion(.success(credential))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }
}

// MARK: - Auth Errors
enum AuthError: Error, LocalizedError {
    case cancelled
    case invalidCredential
    case noViewController

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled"
        case .invalidCredential:
            return "Invalid credential received"
        case .noViewController:
            return "No view controller available for sign-in"
        }
    }
}
