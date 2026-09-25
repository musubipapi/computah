import AppKit
import SwiftUI
import ComputahCore

@MainActor final class DebugReviewState: ObservableObject {
    @Published var status = "Ready"
    @Published var transcript = ""
    @Published var listening = false
    @Published var running = false
    @Published var savesDiagnostics = false
    @Published var runs: [App.RunRecord] = []

    func update(status: String, transcript: String, listening: Bool, running: Bool) {
        // Streaming updates must not reset history selection or scroll position.
        if self.status != status { self.status = status }
        if self.transcript != transcript { self.transcript = transcript }
        if self.listening != listening { self.listening = listening }
        if self.running != running { self.running = running }
    }
}

struct DebugPanel: View {
    @ObservedObject var state: DebugReviewState
    let costs: JevCostStore
    @State private var selection: String?
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    let toggleListening: () -> Void
    let beginCommand: () -> Void
    let submitCommand: (String) -> Void

    private func submit() {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = command
        command = ""
        commandFocused = false
        submitCommand(text)
    }

    private var selectedRun: App.RunRecord? {
        state.runs.first { $0.id == selection } ?? state.runs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Computah Debug").font(.title2.bold())
                    Spacer()
                    Label(state.listening ? "Listening" : "Microphone off",
                          systemImage: state.listening ? "mic.fill" : "mic.slash")
                        .foregroundStyle(state.listening ? Color.accentColor : .secondary)
                    Button(state.listening ? "Stop listening" : "Start listening", action: toggleListening)
                }
                HStack(alignment: .top, spacing: 8) {
                    if state.running { ProgressView().controlSize(.small) }
                    Text(state.status).font(.callout).textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("CURRENT INPUT").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        Text(state.transcript.isEmpty ? "Your spoken or typed command will appear here." : state.transcript)
                            .font(.title3).textSelection(.enabled)
                            .foregroundStyle(state.transcript.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 55)
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    TextField("Type a command…", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Debug command")
                        .focused($commandFocused)
                        .onSubmit { submit() }
                    Button("Run") { submit() }
                        .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                JevCostView(store: costs)
                Text("Run hides this panel while the command executes. Reopen Debug Mode to check the result.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("RECENT COMMANDS").font(.caption.bold()).foregroundStyle(.secondary)
                        .padding(14)
                    List(selection: $selection) {
                        ForEach(state.runs) { run in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(run.command).font(.body.weight(.medium)).lineLimit(2)
                                HStack {
                                    Text(run.recordedAt, style: .time)
                                    Spacer()
                                    Text(run.complete == true ? "Confirmed" : run.complete == false ? "Unconfirmed" : "Unknown")
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(run.id)
                        }
                    }.listStyle(.sidebar)
                    if state.runs.isEmpty {
                        Text("No results yet.\nSpeak a command or type one above.")
                            .font(.callout).foregroundStyle(.secondary).padding(14)
                    }
                }.frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                if let run = selectedRun {
                    RunReview(run: run).id(run.id).frame(minWidth: 420)
                } else {
                    ContentUnavailableView("Ready for a command", systemImage: "text.bubble",
                        description: Text("Finished runs appear here with their actions, observed outcomes, and timing."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Label(state.savesDiagnostics
                  ? "Diagnostic saving is on. History may include previous sessions."
                  : "Session history only · diagnostic saving is off.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
        }
        .frame(minWidth: 760, minHeight: 580)
        .onChange(of: commandFocused) { _, focused in
            if focused { beginCommand() }
        }
        .onChange(of: state.runs.first?.id) { old, new in
            // Follow new results only when the user was already viewing the latest.
            if selection == nil || selection == old { selection = new }
        }
    }
}

private struct RunReview: View {
    let run: App.RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(run.command).font(.title3.weight(.semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(run.complete == true ? "Result confirmed" : run.complete == false ? "Completion not confirmed" : "Result unknown",
                  systemImage: run.complete == true ? "checkmark.circle" : "questionmark.circle")
                .foregroundStyle(run.complete == true ? Color.green : Color.secondary)
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        section("What happened", run.status)
                        HStack(alignment: .top, spacing: 28) {
                            metric("Total time", run.elapsed.map(seconds) ?? "—")
                            metric("Steps recorded", run.events.map { String($0.count) } ?? "—")
                            metric("AI attempts", run.requests.map(String.init) ?? "—")
                        }
                        Divider()
                        Text("Actions & results").font(.headline)
                        if (run.events ?? []).isEmpty {
                            section("Recorded action", run.action.flatMap { $0.isEmpty ? nil : $0 } ?? "No action was recorded.")
                            Text("No step details were saved for this command.").foregroundStyle(.secondary)
                        }
                        ForEach(Array((run.events ?? []).enumerated()), id: \.offset) { index, event in
                            HStack(alignment: .top, spacing: 12) {
                                Text(String(index + 1)).font(.callout.monospacedDigit().bold())
                                    .frame(width: 28, height: 28)
                                    .background(.quaternary, in: Circle())
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(event.action).font(.body.weight(.medium)).textSelection(.enabled)
                                    Label(outcomeLabel(event.outcome), systemImage: event.outcome == "complete" ? "checkmark.circle" : "info.circle")
                                        .foregroundStyle(event.outcome == "complete" ? Color.green : .secondary)
                                        .textSelection(.enabled)
                                    Text("Choose & send: \(seconds(event.selectionSeconds)) · Check: \(seconds(event.verificationSeconds))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.tabItem { Text("Overview") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text("What Jev considered for each step. Missing measurements are shown as —.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Total input tokens: \(run.inputTokens.map(String.init) ?? "—")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if (run.events ?? []).isEmpty {
                            Text("No decision details were saved for this command.").foregroundStyle(.secondary)
                        }
                        ForEach(Array((run.events ?? []).enumerated()), id: \.offset) { index, event in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Step \(index + 1) · \(event.clause.text)").font(.headline)
                                Text("App read: \(seconds(event.captureSeconds)) · AI time: \(event.modelSeconds.map(seconds) ?? "—")\nAI attempts: \(event.requests) · Input tokens: \(event.inputTokens.map(String.init) ?? "—") · Recovery reads: \(event.recoveryReads.map(String.init) ?? "—")")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                rawDetails("Selection details", event.selectionDetails ?? "No selection details recorded.")
                                rawDetails("Raw outcome", event.outcome)
                            }
                            Divider()
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.tabItem { Text("Jev decisions") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text("The app controls Computah read before and after each action. These saved observations may be incomplete.")
                            .font(.callout).foregroundStyle(.secondary)
                        if (run.events ?? []).isEmpty {
                            rawDetails("Saved observation", run.observation ?? "No observation recorded.")
                        }
                        ForEach(Array((run.events ?? []).enumerated()), id: \.offset) { index, event in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Step \(index + 1) · \(event.action)").font(.headline)
                                rawDetails("Before action", event.before)
                                rawDetails("After action", event.after)
                            }
                            Divider()
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.tabItem { Text("App controls") }
            }
        }.padding(18)
    }

    private func section(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    private func rawDetails(_ title: String, _ value: String) -> some View {
        DisclosureGroup(title) {
            Text(value.isEmpty ? "No observation recorded." : value)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        }
    }

    private func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }

    // Presentation of recorded protocol values only; never interprets user intent.
    private func outcomeLabel(_ value: String) -> String {
        switch value {
        case "complete": return "Confirmed by observed app state."
        case "progress": return "An intermediate result was observed; more work was needed."
        case "pending", "unknown": return "The result is still unconfirmed."
        case "contradicted": return "The observed result conflicts with the request."
        default: return value
        }
    }
}

struct JevCostView: View {
    @ObservedObject var store: JevCostStore
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Track Jev costs", isOn: Binding(get: { store.total.enabled }, set: store.setEnabled))
                    .toggleStyle(.switch).fixedSize()
                    .help("Save a running cost estimate across launches. This stores totals only, without commands or app content.")
                Spacer()
                if store.total.enabled || store.total.requests > 0 {
                    Text(String(format: "Estimated total: $%.6f USD", store.total.estimatedUSD))
                        .monospacedDigit()
                    Button("Reset…") { confirmingReset = true }
                }
            }
            if store.total.enabled || store.total.requests > 0 {
                Text("\(store.total.requests) requests · \(store.total.inputTokens) reported input tokens · Since \(store.total.since.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if store.total.missingUsage > 0 || store.total.unpricedTokens > 0 {
                    Text("Incomplete estimate: \(store.total.missingUsage) requests lack reported usage; \(store.total.unpricedTokens) tokens have no known price.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("\(JevCosts.pricedModel): $\(String(format: "%.3f", JevCosts.inputUSDPerMillion)) / million input tokens. Output is free. \(store.total.enabled ? "" : "Tracking paused.")")
                    Link("Pricing", destination: URL(string: "https://docs.typesafe.ai/models")!)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.storageError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    if !store.total.enabled && store.total.requests == 0 {
                        Button("Reset…") { confirmingReset = true }
                    }
                }
            }
        }
        .confirmationDialog("Reset the saved Jev cost total?", isPresented: $confirmingReset) {
            Button("Reset total", role: .destructive) { store.reset() }
        } message: {
            Text("This clears only the local counter. It does not change your TypeSafe bill.")
        }
    }
}
