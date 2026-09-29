// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-d229239e00854fc467a4cdd23427122d51894f4e29089bc0d7ead4eea02f21c6"
// Source-SHA256: "c99a690cefd985836b145c2b3bcae050a45847c2e2906ecae3ba4ed6f3844a2f"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

/// Product intro page (English v1)
/// Brand: Solara AI
struct AboutSoraView: View {

    var body: some View {
        ZStack {
            background

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {

                    header

                    Divider()
                        .overlay(Color.white.opacity(0.18))

                    valueProps

                    howItWorks

                    proRule

                    notes

                    Spacer().frame(height: 18)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.22, green: 0.30, blue: 0.44),
                Color(red: 0.16, green: 0.26, blue: 0.42),
                Color(red: 0.08, green: 0.12, blue: 0.27)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is Solara AI?")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text("Solara AI is an AI video studio that turns your ideas into short-form videos — fast. Type a prompt, speak a brief, or upload a photo/clip, and generate share-ready videos with a polished look.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.88))
                .lineSpacing(3)

            HStack(spacing: 10) {
                Pill(text: "Text → Video")
                Pill(text: "Voice → Video")
                Pill(text: "Photo/Clip → Video")
            }
        }
    }

    // MARK: - Sections

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("What you can do")

            Bullet(text: "Create vertical videos for TikTok, Instagram Reels, and YouTube Shorts.")
            Bullet(text: "Prototype ads and product videos without a production crew.")
            Bullet(text: "Turn ideas, scripts, and everyday moments into share-ready clips.")
            Bullet(text: "Use one app: type, speak, or upload — then generate and export.")
        }
        .cardStyle()
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Three ways to create")

            FeatureCard(
                icon: "text.alignleft",
                title: "Text → Video",
                detail: "Write 1–2 sentences about the scene, mood, and style. Solara AI helps structure shots and motion to produce a clean short video."
            )

            FeatureCard(
                icon: "mic.fill",
                title: "Voice → Video",
                detail: "Talk like you're briefing a creative team. Solara AI turns your intent into a concise plan and a finished video."
            )

            FeatureCard(
                icon: "photo.on.rectangle",
                title: "Photo / Clip → New Video",
                detail: "Upload a photo or short clip. Solara AI can extend the scene and generate a new video based on your direction."
            )
        }
    }

    private var proRule: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Free vs Pro")

            Bullet(text: "Free: Browse and watch examples.")
            Bullet(text: "Pro: Generate videos, use realtime voice, and save/share full results.")

            Text("If you like what you see in the examples, Pro unlocks the full creation workflow in the main page.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.78))
                .lineSpacing(2)
        }
        .cardStyle()
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Notes")

            Text("• Generation quality depends on your prompt and input media.\n• Internet connection is required.\n• Brand name shown to users is Solara AI.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(3)
        }
        .cardStyle(opacity: 0.08)
    }
}

// MARK: - Small Components

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
    }
}

private struct Bullet: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.88))
                .lineSpacing(2)
        }
    }
}

private struct Pill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let detail: String   // ✅ avoid naming conflict with SwiftUI `body`

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)

                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .lineSpacing(2)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension View {
    func cardStyle(opacity: Double = 0.10) -> some View {
        self
            .padding(14)
            .background(Color.white.opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
