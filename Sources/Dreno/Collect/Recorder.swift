import Foundation

struct LiveItem: Identifiable, Hashable {
    let id: String
    let name: String
    let pct: Double
}

struct LiveStatus {
    let sessionId: Int64
    let started: Date
    let ticks: Int
    let power: PowerReading
    let busyPct: Double?
    let top: [LiveItem]
    let overheadPct: Double
}

/// Grava amostras de todos os processos a cada intervalo, numa fila própria.
final class Recorder {
    let sessionId: Int64
    let started: Date
    let interval: TimeInterval
    var onTick: ((LiveStatus) -> Void)?

    private let db: Database
    private let queue = DispatchQueue(label: "dreno.recorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var k = 0
    private var lastT = 0.0
    private var lastHost: (busy: UInt64, total: UInt64)?
    private var finished = false

    private struct Track {
        var rowId: Int64
        var path: String
        var cpu: Double
        var energy: UInt64?
        var wake: UInt64?
        var gpu: UInt64?
        var lastSeen: Double
        var liveName: String
    }
    private var tracks: [Int32: Track] = [:]
    private var liveRing: [[String: Double]] = []
    private let myUID = getuid()
    private let ncpu = Double(MacInfo.ncpu)
    private let memEvery: Int
    private var selfCPUStart = 0.0

    private let insProc: Statement
    private let insSample: Statement
    private let insTick: Statement
    private let insHold: Statement
    private let updLast: Statement

    init(db: Database, interval: TimeInterval, trigger: String) throws {
        self.db = db
        self.interval = interval
        self.started = Date()
        memEvery = max(1, Int((60 / interval).rounded()))
        let power = PowerProbe.read()
        // Baterias dos MacBooks atuais têm ~11,45 V nominais.
        let wh: Double? = power.hasBattery ? power.nominalMah.map { $0 * 11.45 / 1000 } : nil
        guard let ins = db.prepare("INSERT INTO sessions(started, interval, trigger, host, ncpu, battery_wh) VALUES(?,?,?,?,?,?)") else {
            throw DBError.prepare("sessions")
        }
        ins.bind(started.timeIntervalSince1970, interval, trigger, "\(MacInfo.model) · \(MacInfo.osVersion)", MacInfo.ncpu, wh).run()
        sessionId = db.lastInsertID

        func prep(_ sql: String) throws -> Statement {
            guard let s = db.prepare(sql) else { throw DBError.prepare(sql) }
            return s
        }
        insProc = try prep("INSERT INTO procs(session,pid,ppid,uid,name,path,rpath,args,first,last) VALUES(?,?,?,?,?,?,?,?,?,?)")
        insSample = try prep("INSERT INTO samples(session,k,proc,cpu,mem,energy,wakeups,gpu) VALUES(?,?,?,?,?,?,?,?)")
        insTick = try prep("INSERT OR REPLACE INTO ticks(session,k,t,dt,busy,resid,watts,batt,on_batt,charging,thermal,pressure,memsnap) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)")
        insHold = try prep("INSERT INTO holds(session,k,proc,pid,type,name,secs) VALUES(?,?,?,?,?,?,?)")
        updLast = try prep("UPDATE procs SET last=? WHERE id=?")
    }

    func start() {
        selfCPUStart = Self.selfCPU()
        queue.async { [self] in
            sample(prime: true)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
            t.setEventHandler { [weak self] in self?.sample(prime: false) }
            t.resume()
            timer = t
        }
    }

    func stop(sync: Bool = false, completion: (() -> Void)? = nil) {
        let work = { [self] in
            timer?.cancel()
            timer = nil
            finish()
        }
        if sync {
            queue.sync(execute: work)
            completion?()
        } else {
            queue.async {
                work()
                if let completion { DispatchQueue.main.async(execute: completion) }
            }
        }
    }

    // MARK: - Amostragem

    private func sample(prime: Bool) {
        guard !finished else { return }
        let now = Date().timeIntervalSince1970
        if !prime { k += 1 }
        let dt = lastT > 0 ? max(0.5, now - lastT) : interval
        lastT = now

        let rows = ProcessLister.list()
        guard !rows.isEmpty else { return }
        let gpuNow = GPUProbe.times()
        let host = HostCPU.ticks()
        let power = PowerProbe.read()
        let memsnap = !prime && ((k - 1) % memEvery == 0)

        var busyPct: Double?
        var busySec = 0.0
        if let h = host, let l = lastHost, h.total > l.total, h.busy >= l.busy {
            let frac = Double(h.busy - l.busy) / Double(h.total - l.total)
            busyPct = frac * 100
            busySec = frac * ncpu * dt
        }
        lastHost = host

        var seen = Set<Int32>(minimumCapacity: rows.count)
        var sumCPU = 0.0
        var live: [String: Double] = [:]

        db.exec("BEGIN")
        for r in rows {
            seen.insert(r.pid)
            let mine = r.uid == myUID
            let usage = mine ? ProcInfo.usage(r.pid) : nil
            let path = r.command.hasPrefix("/") ? r.command : (ProcInfo.path(r.pid) ?? r.command)

            var tr: Track
            var fresh = false
            if let old = tracks[r.pid], old.path == path, r.cpuTime + 0.05 >= old.cpu {
                tr = old
            } else {
                if let old = tracks[r.pid] { updLast.bind(old.lastSeen, old.rowId).run() }
                let name = (path as NSString).lastPathComponent
                var rpath: String?
                if mine, let rp = ProcInfo.responsible(r.pid) { rpath = ProcInfo.path(rp) }
                var args: String?
                if mine, ProcInfo.wantsArgs(name), let a = ProcInfo.args(r.pid) { args = ProcInfo.summarize(args: a) }
                insProc.bind(sessionId, Int(r.pid), Int(r.ppid), Int(r.uid), name, path, rpath, args, now, now).run()
                tr = Track(rowId: db.lastInsertID, path: path, cpu: 0, energy: nil, wake: nil, gpu: nil,
                           lastSeen: now, liveName: AppCatalog.shared.liveName(path: path))
                fresh = true
            }

            // CPU: diferença do tempo acumulado. Processo novo no meio da gravação conta desde o início dele.
            let baseCPU = fresh ? (prime ? r.cpuTime : 0) : tr.cpu
            let dCPU = max(0, r.cpuTime - baseCPU)
            tr.cpu = r.cpuTime

            var dEnergy: Double?
            var dWake: Double?
            if let u = usage {
                let baseE = fresh ? (prime ? u.energyNJ : 0) : (tr.energy ?? u.energyNJ)
                let baseW = fresh ? (prime ? u.idleWakeups : 0) : (tr.wake ?? u.idleWakeups)
                dEnergy = u.energyNJ >= baseE ? Double(u.energyNJ - baseE) / 1e9 : 0
                dWake = u.idleWakeups >= baseW ? Double(u.idleWakeups - baseW) : 0
                tr.energy = u.energyNJ
                tr.wake = u.idleWakeups
            }

            var dGPU = 0.0
            if let g = gpuNow[r.pid] {
                let baseG = (prime && fresh) ? g : (tr.gpu ?? 0)
                dGPU = g >= baseG ? Double(g - baseG) / 1e9 : 0
                tr.gpu = g
            }
            tr.lastSeen = now
            tracks[r.pid] = tr
            if prime { continue }

            sumCPU += dCPU
            let mem: Double = usage.map { Double($0.footprint) } ?? r.rss
            let active = dCPU >= 0.005 || dGPU >= 0.005 || (dEnergy ?? 0) >= 0.01
            if active || (memsnap && mem >= 10_000_000) {
                let memVal: Double? = memsnap ? mem : nil
                let gpuVal: Double? = dGPU > 0 ? dGPU : nil
                insSample.bind(sessionId, k, tr.rowId, dCPU, memVal, dEnergy, dWake, gpuVal).run()
            }
            if dCPU > 0 { live[tr.liveName, default: 0] += dCPU / dt * 100 }
        }

        let gone = tracks.keys.filter { !seen.contains($0) }
        for pid in gone {
            if let tr = tracks[pid] { updLast.bind(tr.lastSeen, tr.rowId).run() }
            tracks[pid] = nil
        }

        if !prime {
            let resid: Double? = busyPct != nil ? max(0, busySec - sumCPU) : nil
            insTick.bind(sessionId, k, now, dt, busyPct, resid, power.watts, power.percent, power.onBattery, power.charging,
                         ProcessInfo.processInfo.thermalState.rawValue, MemoryPressure.level(), memsnap).run()
            // Um registro por processo e tipo a cada amostra, valendo o intervalo dela.
            var holdMap: [String: (pid: Int32, type: String, names: [String])] = [:]
            for h in SleepHolds.read() where !SleepHolds.isNoise(h.name) {
                let key = "\(h.pid)|\(h.type)"
                var e = holdMap[key] ?? (h.pid, h.type, [])
                if !h.name.isEmpty, e.names.count < 3, !e.names.contains(h.name) { e.names.append(h.name) }
                holdMap[key] = e
            }
            for e in holdMap.values {
                let rowId: Int64? = tracks[e.pid]?.rowId
                insHold.bind(sessionId, k, rowId, Int(e.pid), e.type, e.names.joined(separator: "\n"), dt).run()
            }
            if k % 30 == 0 {
                for tr in tracks.values { updLast.bind(tr.lastSeen, tr.rowId).run() }
            }
        }
        db.exec("COMMIT")

        guard !prime else { return }
        liveRing.append(live)
        if liveRing.count > memEvery { liveRing.removeFirst() }
        var agg: [String: Double] = [:]
        for m in liveRing { for (n, v) in m { agg[n, default: 0] += v } }
        let count = Double(liveRing.count)
        let top = agg.sorted { $0.value > $1.value }.prefix(6).map { LiveItem(id: $0.key, name: $0.key, pct: $0.value / count) }
        let overhead = (Self.selfCPU() - selfCPUStart) / max(1, now - started.timeIntervalSince1970) * 100
        let status = LiveStatus(sessionId: sessionId, started: started, ticks: k, power: power, busyPct: busyPct, top: top, overheadPct: overhead)
        if let cb = onTick { DispatchQueue.main.async { cb(status) } }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let now = Date().timeIntervalSince1970
        db.exec("BEGIN")
        for tr in tracks.values { updLast.bind(tr.lastSeen, tr.rowId).run() }
        let overhead = (Self.selfCPU() - selfCPUStart) / max(1, now - started.timeIntervalSince1970) * 100
        db.prepare("UPDATE sessions SET ended=?, overhead=? WHERE id=?")?.bind(now, overhead, sessionId).run()
        db.exec("COMMIT")
    }

    /// CPU usada pelo próprio Dreno (inclui os ps que ele dispara).
    static func selfCPU() -> Double {
        var a = rusage()
        getrusage(RUSAGE_SELF, &a)
        var b = rusage()
        getrusage(RUSAGE_CHILDREN, &b)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(a.ru_utime) + s(a.ru_stime) + s(b.ru_utime) + s(b.ru_stime)
    }
}
