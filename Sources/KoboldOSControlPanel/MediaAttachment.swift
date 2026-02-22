import SwiftUI
import AppKit
import Foundation

// MARK: - MediaAttachment

struct MediaAttachment: Identifiable, Sendable {
    let id: UUID
    enum MediaType: Sendable { case image, video, audio, file }
    let mediaType: MediaType
    let url: URL
    let name: String
    let imageData: Data?      // raw bytes for vision API
    let thumbnailImage: NSImage?  // display thumbnail
    let fileSize: Int64

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.name = url.lastPathComponent
        self.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) } ?? 0

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff":
            self.mediaType = .image
            let data = try? Data(contentsOf: url)
            self.imageData = data
            self.thumbnailImage = data.flatMap { NSImage(data: $0) }
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            self.mediaType = .video
            self.imageData = nil
            self.thumbnailImage = nil
        case "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus":
            self.mediaType = .audio
            self.imageData = nil
            self.thumbnailImage = nil
        default:
            self.mediaType = .file
            self.imageData = nil
            self.thumbnailImage = nil
        }
    }

    var systemIcon: String {
        switch mediaType {
        case .image: return "photo.fill"
        case .video: return "video.fill"
        case .audio: return "waveform"
        case .file:  return "doc.fill"
        }
    }

    var accentColor: Color {
        switch mediaType {
        case .image: return .koboldEmerald
        case .video: return .blue
        case .audio: return .purple
        case .file:  return .koboldGold
        }
    }

    var base64: String? {
        guard mediaType == .image, let data = imageData else { return nil }
        return data.base64EncodedString()
    }

    var formattedSize: String {
        if fileSize < 1024 { return "\(fileSize) B" }
        if fileSize < 1024 * 1024 { return "\(fileSize / 1024) KB" }
        return String(format: "%.1f MB", Double(fileSize) / (1024 * 1024))
    }
}

// MARK: - AttachmentThumbnail (compact inline chip)

struct AttachmentThumbnail: View {
    let attachment: MediaAttachment
    var onRemove: (() -> Void)? = nil
    var compact: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = attachment.thumbnailImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: compact ? 48 : 72, height: compact ? 48 : 72)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(attachment.accentColor.opacity(0.15))
                            .frame(width: compact ? 48 : 72, height: compact ? 48 : 72)
                        VStack(spacing: 2) {
                            Image(systemName: attachment.systemIcon)
                                .font(.system(size: compact ? 14 : 22))
                                .foregroundColor(attachment.accentColor)
                            if !compact {
                                Text(attachment.name)
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(attachment.accentColor.opacity(0.3), lineWidth: 1)
            )

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
    }
}

// MARK: - AttachmentBubble (full inline in chat)

struct AttachmentBubble: View {
    let attachment: MediaAttachment
    @State private var isExpanded = false

    var body: some View {
        switch attachment.mediaType {
        case .image:
            imageView
        case .video:
            mediaFileView(icon: "video.fill", color: .blue)
        case .audio:
            audioView
        case .file:
            mediaFileView(icon: "doc.fill", color: .koboldGold)
        }
    }

    var imageView: some View {
        Group {
            if let img = attachment.thumbnailImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: isExpanded ? 480 : 220, maxHeight: isExpanded ? 360 : 160)
                    .cornerRadius(10)
                    .onTapGesture { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(4)
                            .background(.ultraThinMaterial)
                            .cornerRadius(4)
                            .padding(4)
                    }
            }
        }
    }

    var audioView: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundColor(.purple)
                .frame(width: 36, height: 36)
                .background(Color.purple.opacity(0.15))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.open(attachment.url) }) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.purple)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.purple.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.2), lineWidth: 1))
        .frame(maxWidth: 280)
    }

    func mediaFileView(icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.15))
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(attachment.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { NSWorkspace.shared.open(attachment.url) }) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(color)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(color.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
        .frame(maxWidth: 280)
    }
}
