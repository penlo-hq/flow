//
//  BriefingService.swift
//  flow
//
//  Fetches pre-meeting briefings from the Enterprise Brain (APP_CONTRACT §6).
//  Falls back to nil on any error so callers can use local Claude generation.
//

import Foundation

struct BriefingBrainResponse: Decodable {
    struct Person: Decodable {
        let name: String
        let roleContext: String?
        let recentTopics: [String]
        let openTasks: [String]
        let lastInteractionDaysAgo: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case roleContext = "role_context"
            case recentTopics = "recent_topics"
            case openTasks = "open_tasks"
            case lastInteractionDaysAgo = "last_interaction_days_ago"
        }
    }

    struct Decision: Decodable {
        let label: String
        let status: String?
    }

    let eventAt: String?
    let people: [Person]
    let relevantDecisions: [Decision]
    let openQuestions: [String]
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case eventAt = "event_at"
        case people
        case relevantDecisions = "relevant_decisions"
        case openQuestions = "open_questions"
        case confidence
    }

    func toBriefing(meetingTitle: String, minutesUntil: Int) -> Briefing {
        let peopleLines = people.map { person -> String in
            var parts = [person.name]
            if let role = person.roleContext, !role.isEmpty {
                parts.append(role)
            }
            if !person.recentTopics.isEmpty {
                parts.append("Topics: " + person.recentTopics.joined(separator: ", "))
            }
            if !person.openTasks.isEmpty {
                parts.append("Tasks: " + person.openTasks.joined(separator: ", "))
            }
            return parts.joined(separator: " — ")
        }

        let decisionLines = relevantDecisions.map { decision in
            if let status = decision.status, !status.isEmpty {
                return "\(decision.label) (\(status))"
            }
            return decision.label
        }

        return Briefing(
            meetingTitle: meetingTitle,
            minutesUntil: minutesUntil,
            peopleContext: peopleLines,
            relevantDecisions: decisionLines,
            openQuestions: openQuestions
        )
    }
}

enum BriefingService {

    /// Returns a brain-generated briefing, or nil if brain is not configured or the request fails.
    static func fetchBriefing(
        meetingTitle: String,
        attendees: [String],
        topics: [String] = [],
        eventAt: Date,
        minutesUntil: Int
    ) async -> Briefing? {
        guard let url = buildBriefingURL(attendees: attendees, topics: topics, eventAt: eventAt),
              let key = KeychainStore.readBrainKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(BriefingBrainResponse.self, from: data)
            return decoded.toBriefing(meetingTitle: meetingTitle, minutesUntil: minutesUntil)
        } catch {
            #if DEBUG
            print("[Penlo Briefing] Brain fetch failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    private static func buildBriefingURL(attendees: [String], topics: [String], eventAt: Date) -> URL? {
        guard let base = brainHostURL() else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("/api/v1/briefing"), resolvingAgainstBaseURL: false)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var items: [URLQueryItem] = attendees.map { URLQueryItem(name: "attendees", value: $0) }
        items += topics.map { URLQueryItem(name: "topics", value: $0) }
        items.append(URLQueryItem(name: "event_at", value: iso.string(from: eventAt)))
        components?.queryItems = items
        return components?.url
    }

    private static func brainHostURL() -> URL? {
        guard let raw = KeychainStore.readBrainURL() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
