import SwiftUI

// MARK: - Agent Cursor State (Phase 7: Virtuelle Maus)

@MainActor
final class AgentCursorState: ObservableObject {
    static let shared = AgentCursorState()

    @Published var isVisible: Bool = false
    @Published var position: CGPoint = .zero
    @Published var label: String = ""
    @Published var isClicking: Bool = false

    private var hideTimer: Timer?

    func show(at point: CGPoint, label: String) {
        self.position = point
        self.label = label
        self.isVisible = true
        resetHideTimer()
    }

    func click(at point: CGPoint) {
        self.position = point
        self.isClicking = true
        self.isVisible = true
        resetHideTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.isClicking = false
        }
    }

    func moveTo(_ point: CGPoint) {
        self.position = point
        self.isVisible = true
        resetHideTimer()
    }

    func hide() {
        self.isVisible = false
        self.label = ""
        self.isClicking = false
    }

    private func resetHideTimer() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hide()
            }
        }
    }
}

// MARK: - Agent Cursor Overlay View

struct AgentCursorOverlay: View {
    @ObservedObject var cursor = AgentCursorState.shared
    @AppStorage("kobold.permission.virtualMouse") private var virtualMouseEnabled: Bool = true
    @State private var rippleScale: CGFloat = 0.3
    @State private var rippleOpacity: Double = 0.8

    var body: some View {
        if virtualMouseEnabled && cursor.isVisible {
            ZStack {
                // Click ripple effect
                if cursor.isClicking {
                    Circle()
                        .stroke(Color.koboldEmerald.opacity(rippleOpacity), lineWidth: 2)
                        .frame(width: 40 * rippleScale, height: 40 * rippleScale)
                        .position(cursor.position)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.5)) {
                                rippleScale = 2.0
                                rippleOpacity = 0
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                rippleScale = 0.3
                                rippleOpacity = 0.8
                            }
                        }
                }

                // Cursor icon
                VStack(spacing: 2) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.koboldEmerald)
                        .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 1)
                        .scaleEffect(cursor.isClicking ? 0.85 : 1.0)
                        .animation(.spring(response: 0.2), value: cursor.isClicking)

                    // Label tooltip
                    if !cursor.label.isEmpty {
                        Text(cursor.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.75))
                            )
                            .offset(y: 4)
                    }
                }
                .position(cursor.position)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: cursor.position)
            }
            .allowsHitTesting(false)
        }
    }
}
