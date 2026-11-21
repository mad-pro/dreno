import Foundation

struct SessionSummary: Identifiable, Hashable {
    let id: Int64
    var title: String?
    let started: Date
    var ended: Date?
    let interval: Double
    let trigger: String
    let host: String?
    let ncpu: Int
    let batteryWh: Double?
    var overhead: Double?
    var batteryStart: Double?
    var batteryEnd: Double?
    var lastTick: Date?

    var duration: Double { (ended ?? lastTick ?? started).timeIntervalSince(started) }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return Fmt.dateTime(started) + (trigger == "bateria" ? " na bateria" : "")
    }
}

/// Consultas pequenas de sessões (lista, renomear, apagar).
enum Store {
    static let reader: Database? = try? Database(path: Paths.database.path)

    static func sessions(in db: Database? = reader) -> [SessionSummary] {
        guard let db, let st = db.prepare("""
            SELECT s.id, s.title, s.started, s.ended, s.interval, s.trigger, s.host, s.ncpu, s.battery_wh, s.overhead,
              (SELECT batt FROM ticks WHERE session=s.id ORDER BY k ASC LIMIT 1),
              (SELECT batt FROM ticks WHERE session=s.id ORDER BY k DESC LIMIT 1),
              (SELECT MAX(t) FROM ticks WHERE session=s.id)
            FROM sessions s ORDER BY s.started DESC
            """) else { return [] }
        st.bind()
        var out: [SessionSummary] = []
        while st.next() {
            out.append(SessionSummary(
                id: st.int(0),
                title: st.text(1),
                started: Date(timeIntervalSince1970: st.double(2)),
                ended: st.optDouble(3).map { Date(timeIntervalSince1970: $0) },
                interval: st.double(4),
                trigger: st.text(5) ?? "manual",
                host: st.text(6),
                ncpu: Int(st.int(7)),
                batteryWh: st.optDouble(8),
                overhead: st.optDouble(9),
                batteryStart: st.optDouble(10),
                batteryEnd: st.optDouble(11),
                lastTick: st.optDouble(12).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return out
    }

    /// Fecha sessões que ficaram abertas (app fechado no meio) e remove as vazias.
    static func closeDangling(in db: Database? = reader) {
        guard let db else { return }
        db.exec("""
        UPDATE sessions SET ended = COALESCE((SELECT MAX(t) FROM ticks WHERE session = sessions.id), started)
          WHERE ended IS NULL;
        DELETE FROM procs WHERE session IN (SELECT id FROM sessions WHERE id NOT IN (SELECT DISTINCT session FROM ticks));
        DELETE FROM holds WHERE session IN (SELECT id FROM sessions WHERE id NOT IN (SELECT DISTINCT session FROM ticks));
        DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session FROM ticks);
        """)
    }

    static func delete(_ id: Int64, in db: Database? = reader) {
        guard let db else { return }
        for table in ["samples", "ticks", "holds", "procs"] {
            db.prepare("DELETE FROM \(table) WHERE session=?")?.bind(id).run()
        }
        db.prepare("DELETE FROM sessions WHERE id=?")?.bind(id).run()
    }

    static func rename(_ id: Int64, _ title: String, in db: Database? = reader) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        db?.prepare("UPDATE sessions SET title=? WHERE id=?")?.bind(t.isEmpty ? nil : t, id).run()
    }
}
