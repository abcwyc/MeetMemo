import EventKit
import Foundation

struct ReminderListOption: Identifiable, Hashable {
    let id: String
    let title: String
    let isDefault: Bool
}

enum ReminderManagerError: LocalizedError {
    case accessDenied
    case noDefaultList
    case listNotFound
    case reminderNotFound
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "MeetMemo 没有提醒事项访问权限，请在系统设置中允许访问提醒事项。"
        case .noDefaultList:
            return "提醒事项 App 中没有可用的默认列表，请先创建或设置一个提醒列表。"
        case .listNotFound:
            return "找不到选中的提醒列表，请重新选择。"
        case .reminderNotFound:
            return "这个提醒事项可能已在系统提醒事项 App 中删除。"
        case .emptyTitle:
            return "任务标题不能为空。"
        }
    }
}

@MainActor
final class ReminderManager {
    static let shared = ReminderManager()

    private let eventStore = EKEventStore()

    private init() {}

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccessIfNeeded() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess {
            return
        }

        guard status == .notDetermined else {
            throw ReminderManagerError.accessDenied
        }

        let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            eventStore.requestFullAccessToReminders { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }

        guard granted else {
            throw ReminderManagerError.accessDenied
        }
    }

    func reminderLists() async throws -> [ReminderListOption] {
        try await requestAccessIfNeeded()
        let defaultIdentifier = eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
        return eventStore.calendars(for: .reminder)
            .map {
                ReminderListOption(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    isDefault: $0.calendarIdentifier == defaultIdentifier
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func defaultReminderListIdentifier() async throws -> String {
        try await requestAccessIfNeeded()
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ReminderManagerError.noDefaultList
        }
        return calendar.calendarIdentifier
    }

    func createReminder(
        for task: MeetingFollowUpTask,
        meeting: Meeting,
        listIdentifier: String?
    ) async throws -> (identifier: String, listIdentifier: String, listTitle: String) {
        try await requestAccessIfNeeded()

        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ReminderManagerError.emptyTitle
        }

        let calendar: EKCalendar
        if let listIdentifier, !listIdentifier.isEmpty {
            guard let selectedCalendar = eventStore.calendars(for: .reminder).first(where: { $0.calendarIdentifier == listIdentifier }) else {
                throw ReminderManagerError.listNotFound
            }
            calendar = selectedCalendar
        } else if let defaultCalendar = eventStore.defaultCalendarForNewReminders() {
            calendar = defaultCalendar
        } else {
            throw ReminderManagerError.noDefaultList
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes(for: task, meeting: meeting)

        if let dueDate = task.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        try eventStore.save(reminder, commit: true)
        return (reminder.calendarItemIdentifier, calendar.calendarIdentifier, calendar.title)
    }

    func removeReminder(identifier: String) async throws {
        try await requestAccessIfNeeded()
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw ReminderManagerError.reminderNotFound
        }

        try eventStore.remove(reminder, commit: true)
    }

    func reminderExists(identifier: String) async throws -> Bool {
        try await requestAccessIfNeeded()
        return eventStore.calendarItem(withIdentifier: identifier) is EKReminder
    }

    private func notes(for task: MeetingFollowUpTask, meeting: Meeting) -> String {
        var lines: [String] = []
        let detail = task.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            lines.append(detail)
        }

        if !meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("来自会议：\(meeting.title)")
        }

        let excerpt = task.sourceExcerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            lines.append("来源片段：\(excerpt)")
        }

        return lines.joined(separator: "\n")
    }
}
