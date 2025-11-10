import SwiftUI
import Supabase

struct UsageDashboardView: View {
    @State private var monthlyUsage: Double = 0
    @State private var monthlyLimit: Double = 8.00
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var providerBreakdown: [ProviderUsage] = []

    var body: some View {
        ZStack {
            Theme.background.edgesIgnoringSafeArea(.all)

            if isLoading {
                ProgressView()
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(Theme.accent)
                    Text(error)
                        .foregroundColor(Theme.secondaryText)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        // MARK: - Usage Summary Card
                        VStack(spacing: 16) {
                            // Header
                            HStack {
                                Image(systemName: "chart.bar.fill")
                                    .font(.title2)
                                    .foregroundColor(Theme.secondaryAccent)
                                Text("This Month")
                                    .font(.headline)
                                    .foregroundColor(Theme.primaryText)
                                Spacer()
                            }

                            // Usage Amount
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("$\(monthlyUsage, specifier: "%.2f")")
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(usageColor)
                                Text("/ $\(monthlyLimit, specifier: "%.2f")")
                                    .font(.title3)
                                    .foregroundColor(Theme.secondaryText.opacity(0.7))
                                Spacer()
                            }

                            // Progress Bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Theme.overlayMask.opacity(0.3))
                                        .frame(height: 8)

                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(usageColor)
                                        .frame(width: geometry.size.width * CGFloat(min(monthlyUsage / monthlyLimit, 1.0)), height: 8)
                                }
                            }
                            .frame(height: 8)

                            // Warning Messages
                            if monthlyUsage >= monthlyLimit {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(Theme.accent)
                                    Text("Limit exceeded")
                                        .font(.subheadline)
                                        .foregroundColor(Theme.accent)
                                    Spacer()
                                }
                            } else if monthlyUsage > monthlyLimit * 0.8 {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(Theme.accent)
                                    Text("Approaching limit")
                                        .font(.subheadline)
                                        .foregroundColor(Theme.accent)
                                    Spacer()
                                }
                            }
                        }
                        .padding(20)
                        .background(Theme.menuAccent)
                        .cornerRadius(16)

                        // MARK: - Provider Breakdown
                        if !providerBreakdown.isEmpty {
                            VStack(spacing: 12) {
                                HStack {
                                    Image(systemName: "square.stack.3d.up.fill")
                                        .font(.title2)
                                        .foregroundColor(Theme.secondaryAccent)
                                    Text("Providers")
                                        .font(.headline)
                                        .foregroundColor(Theme.primaryText)
                                    Spacer()
                                }

                                VStack(spacing: 0) {
                                    ForEach(Array(providerBreakdown.enumerated()), id: \.element.id) { index, usage in
                                        VStack(spacing: 0) {
                                            if index > 0 {
                                                Divider()
                                                    .background(Theme.overlayMask.opacity(0.3))
                                            }

                                            HStack(spacing: 12) {
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(usage.provider.capitalized)
                                                        .font(.body)
                                                        .fontWeight(.medium)
                                                        .foregroundColor(Theme.primaryText)
                                                    Text("\(usage.requestCount) requests")
                                                        .font(.caption)
                                                        .foregroundColor(Theme.secondaryText.opacity(0.7))
                                                }
                                                Spacer()
                                                Text("$\(usage.totalCost, specifier: "%.4f")")
                                                    .font(.system(.body, design: .rounded))
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(Theme.secondaryAccent)
                                            }
                                            .padding(.vertical, 12)
                                        }
                                    }
                                }
                            }
                            .padding(20)
                            .background(Theme.menuAccent)
                            .cornerRadius(16)
                        }

                        // MARK: - Refresh Button
                        Button {
                            Task {
                                await fetchUsage()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh")
                            }
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(Theme.secondaryAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.menuAccent)
                            .cornerRadius(12)
                        }
                        .disabled(isLoading)
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                await fetchUsage()
            }
        }
    }

    private var usageColor: Color {
        if monthlyUsage >= monthlyLimit {
            return Theme.accent
        } else if monthlyUsage > monthlyLimit * 0.8 {
            return Theme.accent
        } else {
            return Theme.secondaryAccent
        }
    }

    func fetchUsage() async {
        isLoading = true
        errorMessage = nil

        do {
            let supabase = AuthService.shared.supabase

            guard let user = AuthService.shared.currentUser else {
                throw NSError(domain: "UsageDashboard", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No authenticated user"
                ])
            }

            // Fetch monthly limit
            let limit: UserLimit = try await supabase
                .from("user_limits")
                .select()
                .eq("user_id", value: user.id)
                .single()
                .execute()
                .value

            monthlyLimit = limit.monthly_limit_usd

            // Fetch current month's usage
            let usage: Double = try await supabase
                .rpc("get_current_month_usage", params: ["p_user_id": user.id])
                .execute()
                .value

            monthlyUsage = usage

            // Fetch provider breakdown
            let startOfMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
            let isoFormatter = ISO8601DateFormatter()
            let startDateISO = isoFormatter.string(from: startOfMonth)

            let logs: [UsageLog] = try await supabase
                .from("usage_logs")
                .select()
                .eq("user_id", value: user.id)
                .gte("timestamp", value: startDateISO)
                .execute()
                .value

            // Aggregate by provider
            var providerMap: [String: (cost: Double, count: Int)] = [:]
            for log in logs {
                let current = providerMap[log.provider] ?? (0, 0)
                providerMap[log.provider] = (current.cost + log.cost_usd, current.count + 1)
            }

            providerBreakdown = providerMap.map { key, value in
                ProviderUsage(
                    provider: key,
                    totalCost: value.cost,
                    requestCount: value.count
                )
            }.sorted { $0.totalCost > $1.totalCost }

        } catch {
            errorMessage = "Failed to load usage: \(error.localizedDescription)"
            print("Usage fetch error: \(error)")
        }

        isLoading = false
    }
}

struct UserLimit: Codable {
    let user_id: String
    let monthly_limit_usd: Double
}

struct UsageLog: Codable {
    let provider: String
    let cost_usd: Double
}

struct ProviderUsage: Identifiable {
    let id = UUID()
    let provider: String
    let totalCost: Double
    let requestCount: Int
}

#Preview {
    NavigationStack {
        UsageDashboardView()
    }
    .preferredColorScheme(.dark)
}
