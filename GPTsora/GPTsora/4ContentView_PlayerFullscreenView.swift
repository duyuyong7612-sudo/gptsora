// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-da74d232a8be6db15685bdda9fc12e4dca8c2eb04784d3cb653efc4ac8610aff"
// Source-SHA256: "7a60490a18df69edd150e066ccd0279928af4fae4d28b80637d2fa4320e9b67c"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI
import AVKit

struct PlayerFullscreenView: View {
    @Binding var isPresented: Bool
    @Binding var player: AVPlayer?
    @Binding var outputVideoURL: URL?
    @Binding var playerDragOffset: CGFloat

    @Binding var showPlayerActions: Bool
    @Binding var showShareSheet: Bool
    @Binding var shareItems: [Any]
    @Binding var nowPlayingPrompt: String

    @Binding var showToast: Bool
    @Binding var toastText: String?

    let onConfigureAudio: () -> Void
    let onSaveToPhotos: () -> Void
    let onShare: () -> Void
    let onCopyPrompt: () -> Void
    let onDelete: () -> Void
    let onToast: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .offset(y: playerDragOffset)
                    .gesture(dragToDismiss)
                    .onAppear {
                        onConfigureAudio()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                            player.volume = 1.0
                            player.seek(to: .zero)
                            player.play()
                        }
                    }
            } else if let url = outputVideoURL {
                Color.black
                    .ignoresSafeArea()
                    .task { @MainActor in
                        let p = AVPlayer(url: url)
                        self.player = p
                        onConfigureAudio()
                        p.volume = 1.0
                        p.seek(to: .zero)
                        p.play()
                    }
            }

            topBar

            if showToast, let t = toastText {
                PlayerToastHUD(text: t)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }
        }
        .confirmationDialog("Video Actions", isPresented: $showPlayerActions, titleVisibility: .visible) {
            Button("Save to Photos") { Haptics.heavy(); onSaveToPhotos() }
            Button("Share") { Haptics.heavy(); onShare() }
            Button("Copy prompt") { Haptics.heavy(); onCopyPrompt() }
            Button("Delete", role: .destructive) { Haptics.heavy(); onDelete() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            PlayerShareSheet(items: shareItems).ignoresSafeArea()
        }
    }

    private var topBar: some View {
        VStack {
            HStack {
                Button {
                    Haptics.heavy()
                    player?.pause()
                    withAnimation(.easeOut(duration: 0.18)) { isPresented = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }

                Spacer()

                Button {
                    Haptics.heavy()
                    showPlayerActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)

            Spacer()

            if !nowPlayingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(nowPlayingPrompt)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.10))
            }
        }
    }

    private var dragToDismiss: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.height < 0 else { return }
                playerDragOffset = value.translation.height
            }
            .onEnded { value in
                guard value.translation.height < 0 else {
                    withAnimation(.spring()) { playerDragOffset = 0 }
                    return
                }
                let predicted = value.predictedEndTranslation.height
                let shouldDismiss = predicted < -120
                if shouldDismiss {
                    Haptics.heavy()
                    player?.pause()
                    withAnimation(.easeOut(duration: 0.18)) {
                        isPresented = false
                        playerDragOffset = 0
                    }
                } else {
                    withAnimation(.spring()) { playerDragOffset = 0 }
                }
            }
    }
}

