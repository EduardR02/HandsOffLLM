import SwiftUI
import Supabase

struct UsageDashboardView: View {
    @State private var monthlyUsage: Double = 0
    @State private var monthlyLimit: Double = 8.00
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var providerBreakdown: [ProviderUsage] = []

    var body: some View {
        List {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                .listRowBackground(Color.clear)
            } else if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(Theme.accent)
                        .font(.caption)
                }
                .listRowBackground(Color.clear)
            } else {
                // MARK: - Usage Summary
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("This Month")
                                .font(.headline)
                            Spacer()
                            Text("$\(monthlyUsage, specifier: "%.2f") / $\(monthlyLimit, specifier: "%.2f")")
                                .font(.headline)
                                .foregroundColor(usageColor)
                        }

                        ProgressView(value: min(monthlyUsage, monthlyLimit), total: monthlyLimit)
                            .tint(usageColor)

                        if monthlyUsage > monthlyLimit * 0.8 {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(Theme.accent)
                                Text("You're approaching your monthly limit")
                                    .font(.caption)
                                    .foregroundColor(Theme.accent)
                            }
                        }

                        if monthlyUsage >= monthlyLimit {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(Theme.accent)
                                Text("Monthly limit exceeded - requests will be blocked")
                                    .font(.caption)
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Usage Summary")
                }
                .listRowBackground(Theme.menuAccent)

                // MARK: - Provider Breakdown
                if !providerBreakdown.isEmpty {
                    Section {
                        ForEach(providerBreakdown) { usage in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(usage.provider.capitalized)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("\(usage.requestCount) requests")
                                        .font(.caption)
                                        .foregroundColor(Theme.secondaryText)
                                }
                                Spacer()
                                Text("$\(usage.totalCost, specifier: "%.4f")")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                        }
                    } header: {
                        Text("By Provider")
                    }
                    .listRowBackground(Theme.menuAccent)
                }

                // MARK: - Refresh Button
                Section {
                    Button {
                        Task {
                            await fetchUsage()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh Usage")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isLoading)
                }
                .listRowBackground(Theme.menuAccent)
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(Theme.background.edgesIgnoringSafeArea(.all))
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
