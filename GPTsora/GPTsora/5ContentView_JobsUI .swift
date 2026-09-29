// GPTsora source provenance (metadata only; existing notices retained)
// Source-ID: "gptsora-3103beeff219b7e89c94332c1e5e9b67d84508f9b52238ba4b360aa889d3c059"
// Source-SHA256: "9c9757fc2034fae77b49795652cf1190ff35f462c27abe4a63cfc19dfbdb76a7"
// Owner: "YUYONG DU"
// License-Reference: "LicenseRef-GPTsora-Noncommercial-1.0; see LICENSE"
// Release-ID: "gptsora-source-2026-09-25"
import SwiftUI

struct JobRingView: View {
    let job: VideoJob
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 44, height: 44)

            switch job.state {
            case .queued, .running:
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                    .frame(width: 26, height: 26)

                Circle()
                    .trim(from: 0.0, to: 0.18)
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                            spin = true
                        }
                    }

                Circle()
                    .trim(from: 0, to: CGFloat(Double(job.progress) / 100.0))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 26, height: 26)
                    .rotationEffect(.degrees(-90))

                Text("\(max(0, min(99, job.progress)))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))

            case .done:
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)

            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.yellow)

            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }
}

struct JobsListSheet: View {
    @ObservedObject var jobManager: VideoJobManager
    let onPlay: (VideoJob) -> Void

    var body: some View {
        NavigationView {
            List {
                ForEach(jobManager.jobs) { j in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(j.prompt)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)

                        HStack {
                            Text(j.state.rawValue.uppercased())
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)

                            Spacer()

                            switch j.state {
                            case .queued, .running:
                                Text("\(j.progress)%")
                                    .font(.system(size: 11, weight: .semibold))
                            case .done:
                                Button("Play") { onPlay(j) }
                                    .font(.system(size: 12, weight: .bold))
                            case .failed:
                                Button("Retry") { jobManager.retry(j.id) }
                                    .font(.system(size: 12, weight: .bold))
                            case .cancelled:
                                Text("CANCELLED")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if j.state == .running {
                            ProgressView(value: Double(j.progress), total: 100)
                        }

                        if j.state == .failed, let err = j.errorText, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.red.opacity(0.9))
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") { jobManager.clearFinished() }
                }
            }
        }
    }
}
