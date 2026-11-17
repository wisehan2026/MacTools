import SwiftUI

struct FeatureHeader: View {
    let feature: Feature
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feature.icon).font(.system(size: 25, weight: .medium)).foregroundStyle(.teal)
                .frame(width: 48, height: 48).background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title).font(.system(size: 23, weight: .semibold))
                Text(feature.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 24).padding(.vertical, 20)
    }
}

struct StatusLine: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.teal)
                Text(text).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }
}

struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}
