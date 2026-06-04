//
//  BriefingScheduler.swift
//  flow
//
//  Connects CalendarManager with ClaudeService to generate and inject
//  real pre-meeting briefings into the chat 15 minutes before events.
//  Runs a check on app foreground and periodically while active.
//

import EventKit
import SwiftData
import SwiftUI

@MainActor
final class BriefingScheduler {

    private let calendar = CalendarManager()

    private var chatVM: ChatViewModel?
    private var modelContext: ModelContext?
    private var checkTask: Task<Void, Never>?
    private var briefedEventIDs = Set<String>()

    func configure(chatVM: ChatViewModel, modelContext: ModelContext) {
        self.chatVM = chatVM
        self.modelContext = modelContext
    }

    /// Call on app foreground or after setup. Only prompts for calendar/notifications when user opted in during onboarding.
    func start() {
        checkTask?.cancel()
        checkTask = Task {
            if SetupState.briefingsOptIn {
                _ = await calendar.requestAccess()
                _ = await NotificationManager.shared.requestAuthorization()
            }
            await checkAndBrief()
            await schedulePeriodicCheck()
        }
    }

    func stop() {
        checkTask?.cancel()
        checkTask = nil
    }

    /// Checks for events within the next 20 minutes and generates briefings.
    private func checkAndBrief() async {
        guard let chatVM, let modelContext else { return }

        let events = calendar.upcomingEvents()
        let now = Date.now

        for event in events {
            let minutesUntil = Int(event.startDate.timeIntervalSince(now) / 60)
            guard minutesUntil > 0 && minutesUntil <= 20 else { continue }

            let eventID = event.eventIdentifier ?? event.title ?? UUID().uuidString
            guard !briefedEventIDs.contains(eventID) else { continue }
            briefedEventIDs.insert(eventID)

            let title = event.title ?? "Upcoming Meeting"
            let attendees = attendeeNames(for: event)
            let topics = title.split(separator: " ").map(String.init).filter { $0.count > 2 }

            if let brainBriefing = await BriefingService.fetchBriefing(
                meetingTitle: title,
                attendees: attendees.isEmpty ? [title] : attendees,
                topics: topics,
                eventAt: event.startDate,
                minutesUntil: minutesUntil
            ) {
                NotificationManager.shared.cacheBriefingSummary(
                    eventID: eventID,
                    summary: brainBriefing.summaryLine
                )
                chatVM.injectBriefing(brainBriefing)
                continue
            }

            guard ClaudeService.hasAPIKey else {
                chatVM.injectBriefing(Briefing(
                    meetingTitle: title,
                    minutesUntil: minutesUntil,
                    peopleContext: [],
                    relevantDecisions: [],
                    openQuestions: []
                ))
                continue
            }

            let context = buildTranscriptContext(from: modelContext)

            do {
                let briefing = try await ClaudeService.shared.generateBriefing(
                    meetingTitle: title,
                    minutesUntil: minutesUntil,
                    transcriptContext: context ?? "No recent conversations captured."
                )
                chatVM.injectBriefing(briefing)
            } catch {
                #if DEBUG
                print("[Penlo Briefing] Generation failed: \(error.localizedDescription)")
                #endif
                chatVM.injectBriefing(Briefing(
                    meetingTitle: title,
                    minutesUntil: minutesUntil,
                    peopleContext: [],
                    relevantDecisions: [],
                    openQuestions: []
                ))
            }
        }

        await NotificationManager.shared.refreshNotifications(for: events)
    }

    private func attendeeNames(for event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }
        return attendees.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func schedulePeriodicCheck() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { break }
            await checkAndBrief()
        }
    }

    private func buildTranscriptContext(from context: ModelContext) -> String? {
        var descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 8

        guard let transcripts = try? context.fetch(descriptor),
              !transcripts.isEmpty else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        return transcripts.compactMap { t -> String? in
            if let payload = t.payload {
                var entry = "[\(formatter.string(from: t.capturedAt))] \(payload.title)"
                if !payload.facts.isEmpty {
                    entry += " — " + payload.facts.map(\.displayText).joined(separator: "; ")
                }
                if !payload.people.isEmpty {
                    entry += " (People: " + payload.peopleNames.joined(separator: ", ") + ")"
                }
                return entry
            } else {
                return "[\(formatter.string(from: t.capturedAt))] \(t.rawText.prefix(100))"
            }
        }.joined(separator: "\n")
    }
}
