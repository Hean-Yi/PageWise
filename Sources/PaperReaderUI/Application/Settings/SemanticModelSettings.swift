import Foundation
import Observation
import PaperReaderKit

@MainActor @Observable
final class SemanticModelSettings {
    static let shared = SemanticModelSettings()
    private let encoder = DeviceSemanticEncoder.shared
    var isBundled: Bool { encoder.isBundled }
    private(set) var installed = false
    private(set) var working = false
    private(set) var errorMessage: String?

    func refresh() async {
        installed = await encoder.isInstalled()
    }

    func changeInstallation(in reader: ReaderModel) async {
        guard !working else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            if installed {
                try await encoder.uninstall()
            } else {
                try await encoder.install()
                reader.paperSearchWarmup.enqueue(reader.state.papers)
                reader.researchBriefMaintenance.sourcesChanged()
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    func cancel() async { await encoder.cancelInstall() }
}
