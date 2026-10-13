import AVFoundation
import Foundation

@main
struct CompareClips {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 3, args[0] != "--help" else { throw CLIError.usage }
            let left = URL(fileURLWithPath: args[0])
            let right = URL(fileURLWithPath: args[1])
            let output = URL(fileURLWithPath: args[2])
            var options = ClipComparison.Options()
            var index = 3
            while index < args.count {
                guard index + 1 < args.count else { throw CLIError.usage }
                let flag = args[index], value = args[index + 1]
                switch flag {
                case "--left-label": options.leftLabel = value
                case "--right-label": options.rightLabel = value
                case "--height": guard let n = Int(value) else { throw CLIError.usage }; options.height = n
                case "--right-offset": guard let n = Double(value) else { throw CLIError.usage }; options.timeAlignment = .offset; options.rightOffset = n
                case "--audio":
                    switch value {
                    case "left": options.includeAudio = true; options.audioSide = .left
                    case "right": options.includeAudio = true; options.audioSide = .right
                    case "none": options.includeAudio = false
                    default: throw CLIError.usage
                    }
                default: throw CLIError.usage
                }
                index += 2
            }
            try await ClipComparison.render(left: left, right: right, output: output, options: options)
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            let track = try await asset.loadTracks(withMediaType: .video).first
            let size = try await track?.load(.naturalSize) ?? .zero
            print("Wrote \(output.path): \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", duration))s — \(options.leftLabel) | \(options.rightLabel)")
        } catch {
            fputs("compare-clips: \(error.localizedDescription)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    enum CLIError: LocalizedError {
        case usage
        var errorDescription: String? { "usage: compare-clips <left> <right> <output.mp4> [--left-label X] [--right-label Y] [--height N] [--right-offset SECONDS] [--audio left|right|none]" }
    }
}
