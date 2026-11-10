import SwiftUI
import AppKit

public struct UpgradePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var triggerReason: String
    public var requiredTier: String

    public init(
        triggerReason: String = "This feature requires a paid ZeroDrive subscription.",
        requiredTier: String = "Creator"
    ) {
        self.triggerReason = triggerReason
        self.requiredTier = requiredTier
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)

                Text("Unlock ZeroDrive \(requiredTier)")
                    .font(.title2.bold())

                Text(triggerReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(.top, 8)

            // Tier Cards
            HStack(spacing: 14) {
                UpgradeTierCard(
                    title: "Creator",
                    price: "$29/mo",
                    subprice: "or $197/year (Save 43%)",
                    badge: "MOST POPULAR",
                    isFeatured: true,
                    features: [
                        "512 GB DFY Cloud Storage (Zero config)",
                        "Multi-Drive in Finder (Work + Personal)",
                        "4 Machine Slots (Mac, VPS, Mini)",
                        "24/7 Hosted Agent MCP Server Token",
                        "High-speed cloud-to-cloud transfers"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "creator")
                        dismiss()
                    }
                )

                UpgradeTierCard(
                    title: "Studio",
                    price: "$49/mo",
                    subprice: "or $397/year",
                    badge: "UNLIMITED",
                    isFeatured: false,
                    features: [
                        "1 TB High-Speed Cloud Storage",
                        "Unlimited Independent Drives",
                        "Unlimited Machine Slots",
                        "Multi-Node Fleet Rendering",
                        "Agent Skill Registry & Priority Bandwidth"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "studio")
                        dismiss()
                    }
                )
            }
            .frame(maxWidth: .infinity)

            // Comparison note
            Text("Free Starter accounts include 10 GB BYOK Cloudflare storage and 1 Vault. Paid accounts include zero-setup DFY storage, multi-drive Finder isolation, and 24/7 AI agent access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            // Actions
            HStack(spacing: 12) {
                Button("Continue with Free (10 GB)") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)

                Button {
                    openStripeCheckout(tier: "creator")
                    dismiss()
                } label: {
                    Label("Upgrade to Creator ($29/mo)", systemImage: "bolt.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.bottom, 6)
        }
        .padding(24)
        .frame(width: 580)
    }

    private func openStripeCheckout(tier: String) {
        let checkoutURL = "https://api.zerodrive.dev/v1/billing/checkout?tier=\(tier)"
        if let url = URL(string: checkoutURL) {
            NSWorkspace.shared.open(url)
        }
    }
}

public struct UpgradeTierCard: View {
    public let title: String
    public let price: String
    public let subprice: String
    public let badge: String
    public let isFeatured: Bool
    public let features: [String]
    public let onSelect: () -> Void

    public var body: some View {
        cardContent
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
    }

    private var cardBackground: some View {
        isFeatured ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(isFeatured ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isFeatured ? 2 : 1)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            priceSection
            Divider()
            featureList
            Spacer()
            actionButton
        }
    }

    private var headerRow: some View {
        HStack {
            Text(title).font(.headline.bold())
            Spacer()
            Text(badge)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isFeatured ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundStyle(isFeatured ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(price).font(.title.bold())
            Text(subprice).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(features, id: \.self) { feat in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isFeatured ? Color.accentColor : Color.green)
                    Text(feat)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        let label = "Select " + title
        if isFeatured {
            Button(action: onSelect) {
                Text(label)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button(action: onSelect) {
                Text(label)
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
