import Foundation
import SQLite3

struct PythonBridge {
    var databasePath: String = {
        if let envPath = ProcessInfo.processInfo.environment["LINKEDIN_APPS_DB"], !envPath.isEmpty {
            return envPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/LinkInJob/applications.db")
    }()

    func fetchApplications() async throws -> [ApplicationItem] {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return []
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }

        let hasStarred = hasColumn(db: db, table: "applications", column: "starred")
        let hasAboutEn = hasColumn(db: db, table: "applications", column: "about_job_text_en")
        let hasAboutRu = hasColumn(db: db, table: "applications", column: "about_job_text_ru")
        let displayDescriptionExpr: String
        let originalDescriptionExpr: String
        if hasAboutEn && hasAboutRu {
            displayDescriptionExpr = "COALESCE(NULLIF(about_job_text_ru, ''), NULLIF(about_job_text, ''), NULLIF(about_job_text_en, ''))"
            originalDescriptionExpr = "COALESCE(NULLIF(about_job_text_en, ''), NULLIF(about_job_text, ''))"
        } else {
            displayDescriptionExpr = "about_job_text"
            originalDescriptionExpr = "about_job_text"
        }

        let query = """
        SELECT
            id,
            source_file,
            subject,
            COALESCE(company, 'Unknown'),
            COALESCE(role, ''),
            COALESCE(location, ''),
            email_date,
            updated_at,
            COALESCE(auto_status, 'incoming'),
            manual_status,
            COALESCE(current_status, ''),
            link_url,
            \(displayDescriptionExpr),
            \(originalDescriptionExpr)\(hasStarred ? ", COALESCE(starred, 0)" : "")
        FROM applications
        WHERE NOT (
            COALESCE(current_status, '') = 'manual_sort'
            AND TRIM(COALESCE(link_url, '')) = ''
        )
        ORDER BY COALESCE(updated_at, email_date) DESC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }

        var items: [ApplicationItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dbID = intValue(statement, index: 0)
            let sourceFile = stringValue(statement, index: 1) ?? ""
            let subject = stringValue(statement, index: 2) ?? ""
            let company = stringValue(statement, index: 3) ?? "Unknown"
            let role = stringValue(statement, index: 4) ?? ""
            let location = stringValue(statement, index: 5) ?? ""
            let appliedDate = parseDate(stringValue(statement, index: 6))
            let lastActivityDate = parseDate(stringValue(statement, index: 7))
            let autoStage = mapStatusToStage(stringValue(statement, index: 8))
            let manualStage = mapStatusToStageOptional(stringValue(statement, index: 9))
            let jobURL = stringValue(statement, index: 11)
            let descriptionText = stringValue(statement, index: 12)
            let originalDescriptionText = stringValue(statement, index: 13)
            let starred = hasStarred ? (intValue(statement, index: 14) ?? 0) != 0 : false

            items.append(
                ApplicationItem(
                    id: UUID(),
                    dbID: dbID,
                    company: company,
                    role: role.isEmpty ? "Unknown role" : role,
                    location: location.isEmpty ? "Unknown location" : location,
                    subject: subject,
                    appliedDate: appliedDate,
                    lastActivityDate: lastActivityDate ?? appliedDate,
                    autoStage: autoStage,
                    manualStage: manualStage,
                    sourceFilePath: sourceFile,
                    jobURL: jobURL?.isEmpty == true ? nil : jobURL,
                    descriptionText: descriptionText?.isEmpty == true ? nil : descriptionText,
                    originalDescriptionText: originalDescriptionText?.isEmpty == true ? nil : originalDescriptionText,
                    starred: starred
                )
            )
        }

        return items
    }

    private func stringValue(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func intValue(_ statement: OpaquePointer, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func hasColumn(db: OpaquePointer, table: String, column: String) -> Bool {
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let query = "PRAGMA table_info('\(escapedTable)')"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = stringValue(statement, index: 1), name.caseInsensitiveCompare(column) == .orderedSame {
                return true
            }
        }
        return false
    }

    private func mapStatusToStage(_ value: String?) -> Stage {
        switch (value ?? "").lowercased() {
        case "applied":
            return .applied
        case "interview":
            return .interview
        case "rejected":
            return .rejected
        case "archive":
            return .archive
        case "offer":
            return .offer
        case "manual_sort", "incoming":
            return .inbox
        default:
            return .inbox
        }
    }

    private func mapStatusToStageOptional(_ value: String?) -> Stage? {
        guard let raw = value, !raw.isEmpty else { return nil }
        return mapStatusToStage(raw)
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }

        return ISO8601DateFormatter().date(from: raw)
    }
}
