import CalendarCore
import EventKit
import Foundation

@MainActor
enum QuickActionsVerification {
    static func run(output: URL) async -> Bool {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["check": name, "passed": passed, "detail": detail])
        }
        func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<50 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        let reminders = ReminderProvider.shared
        reminders.refreshLists()
        record("reminder.authorization", reminders.authorized, "system=\(status.rawValue), provider=\(reminders.authorized), lists=\(reminders.lists.count)")
        let store = EKEventStore()
        let day = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: day)!
        let end = start.addingTimeInterval(3600)
        let eventProvider = EventProvider.shared
        eventProvider.refreshCalendars()
        record("event.authorization", eventProvider.authorized)

        if reminders.authorized {
            // Permission is already granted; exercise the callback without creating a new grant.
            reminders.requestAccess()
            await waitFor { !reminders.requestingAccess }
            record("reminder.reconnect-keeps-access", reminders.authorized && !reminders.requestingAccess)
            let list = EKCalendar(for: .reminder, eventStore: store)
            list.title = "CalDock disposable test \(UUID().uuidString.prefix(6))"
            list.source = store.defaultCalendarForNewReminders()?.source ?? store.sources.first { $0.sourceType == .local }
            do {
                try store.saveCalendar(list, commit: true)
                reminders.refreshLists()
                record("reminder.list-published", reminders.lists.contains { $0.id == list.calendarIdentifier && $0.writable })
                reminders.setActive(true, day: day)
                let name = "CalDock disposable reminder \(UUID().uuidString)"
                try reminders.create(title: name, dueDate: start, listID: list.calendarIdentifier)
                await waitFor { reminders.reminders.contains { $0.title == name } }
                if let value = reminders.reminders.first(where: { $0.title == name }) {
                    record("reminder.create-and-list", true)
                    let external = store.calendarItem(withIdentifier: value.id) as? EKReminder
                    record("reminder.system-persisted", external?.title == name && external?.dueDateComponents?.hour == 15 && external?.alarms?.count == 1)
                    let renamed = name + " edited"
                    try reminders.update(value, title: renamed, dueDate: end, listID: list.calendarIdentifier)
                    await waitFor { reminders.reminders.contains { $0.id == value.id && $0.title == renamed } }
                    record("reminder.update-and-list", reminders.reminders.contains { $0.id == value.id && $0.title == renamed && $0.dueDate == end })
                    let afterEdit = store.calendarItem(withIdentifier: value.id) as? EKReminder
                    record("reminder.system-update", afterEdit?.title == renamed && afterEdit?.dueDateComponents?.hour == 16)
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                    reminders.load(day: tomorrow)
                    reminders.load(day: day)
                    await waitFor { !reminders.loading }
                    record("reminder.latest-day-wins", reminders.reminders.contains { $0.id == value.id })
                    if let updated = reminders.reminders.first(where: { $0.id == value.id }) {
                        try reminders.delete(updated)
                        await waitFor { !reminders.reminders.contains { $0.id == value.id } }
                        record("reminder.delete-and-list", !reminders.reminders.contains { $0.id == value.id })
                        record("reminder.system-delete", store.calendarItem(withIdentifier: value.id) == nil)
                    }
                } else { record("reminder.create-and-list", false) }
            } catch { record("reminder.crud", false, error.localizedDescription) }
            do {
                if store.calendar(withIdentifier: list.calendarIdentifier) != nil { try store.removeCalendar(list, commit: true) }
                record("reminder.cleanup", store.calendar(withIdentifier: list.calendarIdentifier) == nil)
            } catch { record("reminder.cleanup", false, error.localizedDescription) }
            reminders.setActive(false, day: day)
        }

        if eventProvider.authorized {
            let list = EKCalendar(for: .event, eventStore: store)
            list.title = "CalDock disposable calendar \(UUID().uuidString.prefix(6))"
            list.source = store.defaultCalendarForNewEvents?.source ?? store.sources.first { $0.sourceType == .local }
            do {
                try store.saveCalendar(list, commit: true)
                await waitFor {
                    eventProvider.refresh()
                    return eventProvider.calendars.contains { $0.id == list.calendarIdentifier && $0.writable }
                }
                record("event.external-calendar-published", eventProvider.calendars.contains { $0.id == list.calendarIdentifier && $0.writable })
                let interval = DateInterval(start: day, duration: 86400)
                let name = "CalDock disposable event \(UUID().uuidString)"
                eventProvider.setActive(true)
                eventProvider.load(range: interval, disabled: [], force: true)
                try eventProvider.create(title: name, start: start, end: end, allDay: false, calendarID: list.calendarIdentifier, location: "Retained location", notes: "Retained notes")
                await waitFor { eventProvider.events.contains { $0.title == name } }
                if let value = eventProvider.events.first(where: { $0.title == name }) {
                    record("event.create-and-list", true)
                    let renamed = name + " edited"
                    try eventProvider.update(value, title: renamed, start: start, end: end.addingTimeInterval(1800), allDay: false, calendarID: list.calendarIdentifier)
                    await waitFor { eventProvider.events.contains { $0.title == renamed } }
                    record("event.update-and-list", eventProvider.events.contains { $0.title == renamed && $0.end == end.addingTimeInterval(1800) })
                    let afterEdit = value.eventIdentifier.flatMap { store.event(withIdentifier: $0) }
                    record("event.system-update-preserves-details", afterEdit?.title == renamed && afterEdit?.notes == "Retained notes" && afterEdit?.location == "Retained location")
                    if let updated = eventProvider.events.first(where: { $0.title == renamed }) {
                        try eventProvider.delete(updated)
                        await waitFor { !eventProvider.events.contains { $0.title == renamed } }
                        record("event.delete-and-list", !eventProvider.events.contains { $0.title == renamed })
                        record("event.system-delete", value.eventIdentifier.flatMap { store.event(withIdentifier: $0) } == nil)
                    }
                } else { record("event.create-and-list", false) }

                let recurring = EKEvent(eventStore: store)
                recurring.calendar = list
                recurring.title = "CalDock disposable recurrence \(UUID().uuidString)"
                recurring.startDate = start; recurring.endDate = end
                recurring.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3)))
                try store.save(recurring, span: .thisEvent, commit: true)
                let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                let nextInterval = DateInterval(start: nextDay, end: Calendar.current.date(byAdding: .day, value: 1, to: nextDay)!)
                eventProvider.load(range: nextInterval, disabled: [], force: true)
                await waitFor { eventProvider.events.contains { $0.title == recurring.title } }
                if let occurrence = eventProvider.events.first(where: { $0.title == recurring.title }) {
                    try eventProvider.update(occurrence, title: "Edited occurrence", start: occurrence.start, end: occurrence.end, allDay: false, calendarID: list.calendarIdentifier)
                    await waitFor { eventProvider.events.contains { $0.title == "Edited occurrence" } }
                    record("event.recurring-update", eventProvider.events.contains { $0.title == "Edited occurrence" && $0.start == occurrence.start })
                    if let edited = eventProvider.events.first(where: { $0.title == "Edited occurrence" }) {
                        try eventProvider.delete(edited)
                        await waitFor { !eventProvider.events.contains { $0.title == "Edited occurrence" } }
                    }
                    let secondDay = store.predicateForEvents(withStart: nextInterval.start, end: nextInterval.end, calendars: [list])
                    record("event.recurring-system-delete", store.events(matching: secondDay).isEmpty)
                    let firstDay = store.predicateForEvents(withStart: day, end: nextDay, calendars: [list])
                    let thirdDay = store.predicateForEvents(withStart: nextInterval.end, end: Calendar.current.date(byAdding: .day, value: 1, to: nextInterval.end)!, calendars: [list])
                    record("event.recurring-preserves-other-occurrences", store.events(matching: firstDay).contains { $0.title == recurring.title }
                           && store.events(matching: thirdDay).contains { $0.title == recurring.title })
                } else { record("event.recurring-lookup", false) }
            } catch { record("event.crud", false, error.localizedDescription) }
            do {
                if store.calendar(withIdentifier: list.calendarIdentifier) != nil { try store.removeCalendar(list, commit: true) }
                record("event.cleanup", store.calendar(withIdentifier: list.calendarIdentifier) == nil)
            } catch { record("event.cleanup", false, error.localizedDescription) }
            eventProvider.setActive(false)
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["passed": passed, "checks": checks, "date": ISO8601DateFormatter().string(from: Date())]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        } catch { return false }
        return passed
    }
}
