import AppKit
import SwiftUI

struct VisionHistoryView: View {
    let session: GameSession
    @Binding var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let calls = session.visionCalls
        let selected = calls.first { $0.id == selection } ?? calls.last

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "eye")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.teal)
                    .frame(width: 36, height: 36)
                    .background(Color.teal.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vision History").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !calls.isEmpty {
                        Text(calls.count == 1 ? "1 call this session" : "\(calls.count) calls this session")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()
            if let selected {
                HStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(calls.reversed()) { call in
                            HStack(spacing: 9) {
                                Image(systemName: call.frame == nil ? "eye.slash" : "photo")
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    if call.openingScan {
                                        Text("Opening Scan").fontWeight(.medium)
                                    } else {
                                        Text("Call #\(call.number)").fontWeight(.medium)
                                    }
                                    Text(call.requestedAt, format: .dateTime.hour().minute().second())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .monospacedDigit()
                            }
                            .padding(.vertical, 5)
                            .accessibilityElement(children: .combine)
                            .tag(call.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(width: 156)
                    .accessibilityLabel("Vision calls")

                    Divider()
                    detail(for: selected)
                }
            } else {
                ContentUnavailableView("No Vision Calls", systemImage: "eye",
                                       description: Text("Opening scans and maps requested by the agent appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 650, idealWidth: 860, minHeight: 410, idealHeight: 575)
        .onChange(of: calls.last?.id, initial: true) { _, latest in
            if !calls.contains(where: { $0.id == selection }) { selection = latest }
        }
    }

    private func detail(for call: VisionCall) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Map #\(call.number)")
                    .font(.headline.monospacedDigit())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Label(call.status.label, systemImage: statusIcon(call.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(call.status == .sent ? Color.teal : Color.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }

            preview(for: call)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor))
                        .allowsHitTesting(false)
                }

            HStack(spacing: 10) {
                Text("Character [\(call.avatar.x), \(call.avatar.y)]")
                Spacer()
                if let frame = call.frame {
                    Text("\(frame.width) × \(frame.height) · PNG")
                    Text(Int64(frame.png.count), format: .byteCount(style: .file))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func preview(for call: VisionCall) -> some View {
        if let frame = call.frame, let image = NSImage(data: frame.png) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("Map with coordinates for vision call \(call.number)")
                .padding(10)
        } else {
            ContentUnavailableView("Map Unavailable", systemImage: "photo", description: Text(call.status.label))
        }
    }

    private func statusIcon(_ status: VisionCall.Status) -> String {
        switch status {
        case .sent: "checkmark.circle.fill"
        case .pending: "clock"
        case .sending: "arrow.up.circle"
        case .cancelled: "minus.circle"
        case .failed, .invalid, .disabled, .renderFailed, .rejected: "exclamationmark.circle"
        }
    }
}
