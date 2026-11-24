import AppKit
import CleanupAssistant
import SwiftUI

struct StorageCleanupAssistantView: View {
    @Bindable var model: StorageCleanupModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cleanupAssistantClient") private var client = "codex"
    @Environment(\.breezeMotionLevel) private var level

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(BreezeStyle.mint)
                    .symbolEffect(.variableColor.iterative, isActive: model.assistantRunning && level.isActive)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI options").font(.title2.weight(.semibold))
                    Text("Ask AI detects your assistant and starts from the cleanup screen. Customize it here if needed.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sharing
                    Divider()
                    conversation
                    Divider()
                    if client == "other" {
                        connection
                    } else {
                        BreezeDisclosure("Manual connection and copy options") { connection.padding(.top, 12) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if let status = model.assistantStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .transition(.breezeDrop)
                }
            }.breezeAnimation(.settle, value: model.assistantStatus == nil)
            HStack {
                Button("Check for proposal") { model.receiveAssistantProposal() }
                    .disabled(!model.assistantSharing || model.assistantSnapshot == nil || model.busy || model.assistantRunning)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 720, height: 690).breezeAction()
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Share cleanup metadata with my assistant", isOn: Binding(
                get: { model.assistantSharing }, set: { model.setAssistantSharing($0) }))
                .toggleStyle(.switch)
                .disabled(model.cleaning)
            Text("Enabled by default. Your choice is remembered across app restarts. Fresh scans are shared automatically while enabled.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Shares item names, sizes, dates, app/project context, shortened paths and recovery advice. File contents, credentials and assistant conversations are excluded. Your assistant may send this metadata to its cloud provider.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snapshot = model.assistantSnapshot {
                Label("\(snapshot.entries.count) items · scan \(snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened)) · expires \(snapshot.expiresAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(BreezeStyle.mint)
            } else {
                Text(model.assistantSharing ? "Sharing is enabled. Finish a fresh scan to share current metadata. Each shared scan expires after four hours." : "Sharing is off until you turn it back on, including after restarting Breeze.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Proposals arrive in Cleanup & apps. You review the items and approve removal in Breeze. Scanning and cleanup use no AI tokens.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your own assistant session").font(.headline)
            if model.assistantExecutable != nil {
                if client == "other", let configuration = model.assistantConfiguration {
                    Text("Merge this server entry into your client's local MCP configuration. Restart or reconnect the client afterward.")
                        .font(.caption).foregroundStyle(.secondary)
                    code(configuration)
                    Button("Copy MCP configuration") { model.copyAssistantText(configuration) }
                } else if let command = model.assistantCommand(for: client) {
                    Text("Run this in Terminal with your installed CLI, then start a new assistant session. Breeze does not change your CLI settings automatically.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    code(command)
                    Button("Copy setup command") { model.copyAssistantText(command) }
                }
            } else {
                Label("BreezeMCP is missing beside this app's executable. Package Breeze with scripts/build.sh to include the local connection.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Sign in with your eligible subscription in the official AI tool to use its included allowance. Existing CLI billing and usage limits apply. Breeze makes no model API calls and has no automatic API billing fallback.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Codex setup", destination: URL(string: "https://developers.openai.com/codex/mcp/")!)
                Link("Claude Code setup", destination: URL(string: "https://code.claude.com/docs/en/mcp")!)
            }.font(.caption)
            HStack {
                Button("Copy prompt for assistant") { model.copyAssistantText(model.assistantPrompt) }
                Button("Copy compact scan summary") { model.copyAssistantSummary() }
                    .disabled(model.inventory == nil || model.busy || model.requiresRescan)
            }
            Text("Copy summary also works without MCP. Pasting it into an assistant shares that metadata with the assistant.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Assistant", selection: $client) {
                Text("Codex").tag("codex")
                Text("Claude Code").tag("claude")
                Text("Other MCP client").tag("other")
            }.pickerStyle(.segmented).disabled(model.assistantRunning)
            Text("Additional priorities (optional)").font(.headline)
            TextField("For example: reclaim 30 GB; keep my AI models and current iOS projects", text: $model.assistantGoal, axis: .vertical)
                .lineLimit(3...5).textFieldStyle(.roundedBorder).disabled(model.assistantRunning)
            if let selectedClient = CleanupAssistantClient(rawValue: client) {
                if let executable = selectedClient.executable {
                    Label("\(selectedClient.name) is installed", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(BreezeStyle.mint).help(executable.path)
                } else {
                    Label("Install \(selectedClient.name)'s official CLI and sign in from Terminal once.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.assistantExecutable == nil {
                    Label("The local Breeze connection is missing. Rebuild the app with scripts/build.sh.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Button { model.runAssistant(client: client) } label: {
                        Label("Analyze with \(selectedClient.name)", systemImage: "sparkles")
                    }
                    .breezeAction(prominent: true)
                    .disabled(model.assistantRunning || !model.assistantSharing || model.assistantSnapshot == nil || model.busy || model.requiresRescan || model.assistantExecutable == nil)
                    if model.assistantRunning {
                        ProgressView().controlSize(.small).transition(.breezeFade)
                        Button("Stop") { model.cancelAssistantAnalysis() }.transition(.breezeFade)
                    }
                }
                Text("Uses your CLI's existing sign-in and usage allowance. No setup command or copying is needed. The assistant reads the shared scan and returns a proposal; you approve removal in Breeze.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let proposal = model.assistantProposal {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Proposal ready · \(proposal.items.count) items", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(BreezeStyle.mint)
                    Text(proposal.summary).font(.caption).textSelection(.enabled)
                    Button("Review proposal") {
                        model.assistantReviewRequested = true
                        dismiss()
                    }.disabled(model.busy || model.requiresRescan || model.assistantRunning)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay { CleanupProposalBorder(proposalID: proposal.id, radius: 10).id(proposal.id) }
                .transition(.breezeDrop)
            }
            if let response = model.assistantResponse {
                BreezeDisclosure("Assistant response") {
                    Text(response).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.transition(.breezeDrop)
            }
        }
        .breezeAnimation(.settle, value: conversationState)
    }

    private var conversationState: String {
        "\(model.assistantRunning)|\(model.assistantProposal?.id ?? "")|\(model.assistantResponse == nil)"
    }

    private func code(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
