import SwiftUI
import AppKit

public struct UpgradePromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var triggerReason: String
    public var requiredTier: String

    public init(
        triggerReason: String = "This feature requires a paid ZeroDrive subscription.",
        requiredTier: String = "Pro"
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

            // Tier Cards: Two Primary Plans (Pro & Agency)
            HStack(spacing: 14) {
                UpgradeTierCard(
                    title: "Pro",
                    price: "$29/mo",
                    subprice: "or $197/year (Save 43%)",
                    badge: "MOST POPULAR",
                    isFeatured: true,
                    features: [
                        "1 TB DFY Cloud Storage (Zero config)",
                        "Free Drive Partitioning (Work, Clients, Personal)",
                        "Unlimited Computers (Mac, Windows, Cloud Servers)",
                        "24/7 Hosted Agent MCP + API Access",
                        "High-speed cloud-to-cloud streaming"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "pro")
                        dismiss()
                    }
                )

                UpgradeTierCard(
                    title: "Agency",
                    price: "$497/mo",
                    subprice: "or $4,970/year",
                    badge: "WHITE-LABEL",
                    isFeatured: false,
                    features: [
                        "10 TB DFY Cloud Storage (+$25/TB add-on)",
                        "Unlimited Segregated Client Vaults",
                        "White-Label Custom Domains & Team MCP",
                        "Unlimited Machines & 5 Team Seats",
                        "Client License Key Issuance & Controls"
                    ],
                    onSelect: {
                        openStripeCheckout(tier: "agency")
                        dismiss()
                    }
                )
            }
            .frame(maxWidth: .infinity)

            // Subtle Free BYOK note
            Text("Free BYOK accounts require connecting your own Cloudflare R2 API keys. Pro & Agency include zero-config managed storage, multi-drive isolation, and 24/7 AI agent access.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            Button("Already have a paid license key? Activate Key…") {
                dismiss()
                NotificationCenter.default.post(name: NSNotification.Name("OpenUpgradeAccountModal"), object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            // Actions
            HStack(spacing: 12) {
                Button("Not Now") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)

                Button {
                    openStripeCheckout(tier: "pro")
                    dismiss()
                } label: {
                    Label("Upgrade to Pro ($29/mo)", systemImage: "bolt.fill")
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
