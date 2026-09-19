import SwiftUI

private struct SpeakerParticipantDraft: Identifiable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct SpeakerNamingSheet: View {
    @EnvironmentObject var langMgr: LanguageManager
    let options: [TranscriptSpeakerNamingOption]
    let participantNames: [String]
    let onCancel: () -> Void
    let onSave: ([String], [String: String]) -> Void

    @State private var participants: [SpeakerParticipantDraft]
    @State private var assignments: [String: UUID]
    @State private var newParticipantName = ""

    init(
        options: [TranscriptSpeakerNamingOption],
        participantNames: [String],
        onCancel: @escaping () -> Void,
        onSave: @escaping ([String], [String: String]) -> Void
    ) {
        self.options = options
        self.participantNames = participantNames
        self.onCancel = onCancel
        self.onSave = onSave

        var seenNames = Set<String>()
        var drafts: [SpeakerParticipantDraft] = []
        for rawName in participantNames {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            drafts.append(SpeakerParticipantDraft(name: name))
        }

        for option in options {
            guard let name = option.currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            drafts.append(SpeakerParticipantDraft(name: name))
        }

        let participantIdByName = Dictionary(uniqueKeysWithValues: drafts.map { ($0.name, $0.id) })
        var initialAssignments: [String: UUID] = [:]
        for option in options {
            guard let name = option.currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let participantId = participantIdByName[name] else { continue }
            initialAssignments[option.id] = participantId
        }

        _participants = State(initialValue: drafts)
        _assignments = State(initialValue: initialAssignments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 18) {
                speakerAssignmentPanel
                    .frame(minWidth: 420, idealWidth: 500, maxWidth: .infinity)

                Divider()
                    .frame(height: 390)

                participantPanel
                    .frame(width: 250)
            }

            footer
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 540)
        .background(ClearInitialFocusView())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(langMgr.t("标记发言人", "Label Speakers"))
                .font(.title3)
                .fontWeight(.semibold)

            Text(langMgr.t(
                "为转录中识别出的默认发言人选择实际参会人。一个参会人可以对应多个默认发言人。",
                "Assign real participant names to detected speaker labels. One participant can map to multiple speaker labels."
            ))
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var speakerAssignmentPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(langMgr.t("默认发言人", "Detected Speakers"))
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(options) { option in
                        speakerAssignmentRow(option)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 410)
        }
    }

    private func speakerAssignmentRow(_ option: TranscriptSpeakerNamingOption) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(option.defaultLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 88, alignment: .leading)

                Picker("", selection: Binding<UUID?>(
                    get: { assignments[option.id] },
                    set: { newValue in
                        assignments[option.id] = newValue
                    }
                )) {
                    Text(langMgr.t("未命名", "Unnamed")).tag(Optional<UUID>.none)
                    ForEach(validParticipants) { participant in
                        Text(participant.name.trimmingCharacters(in: .whitespacesAndNewlines))
                            .tag(Optional(participant.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()
            }

            if !option.sampleTexts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(option.sampleTexts, id: \.self) { sample in
                        Text("\"\(sample)\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(8)
    }

    private var participantPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(langMgr.t("参会人名单", "Participants"))
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if participants.isEmpty {
                        Text(langMgr.t("先添加参会人姓名", "Add participant names first"))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }

                    ForEach($participants) { $participant in
                        HStack(spacing: 6) {
                            BorderlessRoundedTextField(
                                placeholder: langMgr.t("姓名", "Name"),
                                text: $participant.name
                            )
                            .frame(height: 34)

                            Button {
                                removeParticipant(participant.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                            .help(langMgr.t("删除", "Delete"))
                        }
                    }
                }
            }
            .frame(maxHeight: 330)

            Divider()

            HStack(spacing: 8) {
                TextField(langMgr.t("添加姓名", "Add name"), text: $newParticipantName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addParticipant)

                Button {
                    addParticipant()
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(langMgr.t("添加", "Add"))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button(langMgr.t("取消", "Cancel")) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button(langMgr.t("保存", "Save")) {
                onSave(savedParticipantNames, savedMappings)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var validParticipants: [SpeakerParticipantDraft] {
        participants.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var savedParticipantNames: [String] {
        var seenNames = Set<String>()
        var names: [String] = []

        for participant in validParticipants {
            let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seenNames.contains(name) else { continue }
            seenNames.insert(name)
            names.append(name)
        }

        return names
    }

    private var savedMappings: [String: String] {
        let participantNameById = Dictionary(
            uniqueKeysWithValues: validParticipants.map {
                ($0.id, $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        )

        return assignments.reduce(into: [String: String]()) { result, pair in
            guard let name = participantNameById[pair.value], !name.isEmpty else { return }
            result[pair.key] = name
        }
    }

    private func addParticipant() {
        let name = newParticipantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        participants.append(SpeakerParticipantDraft(name: name))
        newParticipantName = ""
    }

    private func removeParticipant(_ id: UUID) {
        participants.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
    }
}
