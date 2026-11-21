import Foundation

/// Transforma as amostras de uma sessão em métricas por app/processo.
enum Analyzer {
    private struct TickRow {
        let k: Int
        let t: Double
        let dt: Double
        let busy: Double?
        let resid: Double?
        let watts: Double?
        let batt: Double?
        let onBatt: Bool
        let thermal: Int
        let pressure: Int
    }

    static func run(db: Database, session: SessionSummary, filter: TickFilter, grouping: Grouping, settings: AnalyzerSettings) -> Report {
        // 1. Amostras do sistema (ticks)
        var allTicks: [TickRow] = []
        if let st = db.prepare("SELECT k,t,dt,busy,resid,watts,batt,on_batt,thermal,pressure FROM ticks WHERE session=? ORDER BY k") {
            st.bind(session.id)
            while st.next() {
                allTicks.append(TickRow(k: Int(st.int(0)), t: st.double(1), dt: st.double(2), busy: st.optDouble(3), resid: st.optDouble(4),
                                        watts: st.optDouble(5), batt: st.optDouble(6), onBatt: st.int(7) == 1,
                                        thermal: Int(st.int(8)), pressure: Int(st.int(9))))
            }
        }
        let ticks = allTicks.filter { tk in
            switch filter {
            case .all: return true
            case .battery: return tk.onBatt
            case .range(let a, let b): return tk.t >= a.timeIntervalSince1970 - 0.001 && tk.t <= b.timeIntervalSince1970 + 0.001
            }
        }
        let n = ticks.count
        var idxOfK = [Int: Int](minimumCapacity: n)
        for (i, tk) in ticks.enumerated() { idxOfK[tk.k] = i }
        let tArr = ticks.map(\.t)
        let windowSec = ticks.reduce(0) { $0 + $1.dt }
        let interval = session.interval

        // 2. Processos e grupos
        var procs: [ProcRow] = []
        if let st = db.prepare("SELECT id,pid,ppid,uid,name,path,rpath,args,first,last FROM procs WHERE session=?") {
            st.bind(session.id)
            while st.next() {
                procs.append(ProcRow(id: st.int(0), pid: Int(st.int(1)), ppid: Int(st.int(2)), uid: Int(st.int(3)), name: st.text(4) ?? "?",
                                     path: st.text(5), rpath: st.text(6), args: st.text(7), first: st.double(8), last: st.double(9)))
            }
        }
        var gIndex: [String: Int] = [:]
        var gKeys: [String] = []
        var gMembers: [[ProcRow]] = []
        var groupOf: [Int64: Int] = [:]
        for p in procs {
            let key = groupKey(p, grouping)
            let gi: Int
            if let e = gIndex[key] { gi = e } else {
                gi = gMembers.count
                gIndex[key] = gi
                gKeys.append(key)
                gMembers.append([])
            }
            gMembers[gi].append(p)
            groupOf[p.id] = gi
        }
        let residualIndex = gMembers.count
        let G = gMembers.count + 1

        // 3. Soma das amostras por grupo e por instante
        var cpu = [[Double]?](repeating: nil, count: G)
        var mem = [[Double]?](repeating: nil, count: G)
        var energy = [Double](repeating: 0, count: G)
        var energyCPU = [Double](repeating: 0, count: G)
        var wake = [Double](repeating: 0, count: G)
        var wakeMeasured = [Bool](repeating: false, count: G)
        var gpu = [Double](repeating: 0, count: G)
        var memberCPU: [Int64: Double] = [:]
        var memberMem: [Int64: (sum: Double, n: Int)] = [:]

        if n > 0, let st = db.prepare("SELECT k,proc,cpu,mem,energy,wakeups,gpu FROM samples WHERE session=?") {
            st.bind(session.id)
            while st.next() {
                guard let i = idxOfK[Int(st.int(0))] else { continue }
                let pid = st.int(1)
                guard let gi = groupOf[pid] else { continue }
                let c = st.double(2)
                if c > 0 {
                    if cpu[gi] == nil { cpu[gi] = [Double](repeating: 0, count: n) }
                    cpu[gi]![i] += c
                    memberCPU[pid, default: 0] += c
                }
                if let m = st.optDouble(3), m > 0 {
                    if mem[gi] == nil { mem[gi] = [Double](repeating: 0, count: n) }
                    mem[gi]![i] += m
                    let cur = memberMem[pid] ?? (0, 0)
                    memberMem[pid] = (cur.sum + m, cur.n + 1)
                }
                if let e = st.optDouble(4) { energy[gi] += e; energyCPU[gi] += c }
                if let w = st.optDouble(5) { wake[gi] += w; wakeMeasured[gi] = true }
                if let g = st.optDouble(6) { gpu[gi] += g }
            }
        }

        // Resíduo: CPU total medida menos a soma dos processos (kernel + processos de vida curta)
        var resid = [Double](repeating: 0, count: n)
        var hasResid = false
        for (i, tk) in ticks.enumerated() { if let r = tk.resid, r > 0 { resid[i] = r; hasResid = true } }
        if hasResid { cpu[residualIndex] = resid }

        // Calibração: joules por segundo de CPU medidos nos processos do usuário, usados pra estimar os do sistema
        let measuredCPU = energyCPU.reduce(0, +)
        let measuredJ = energy.reduce(0, +)
        let jPerCpuSec = measuredCPU >= 20 ? measuredJ / measuredCPU : 1.5
        let hasWatts = ticks.contains { $0.watts != nil }
        let macJ = ticks.reduce(0.0) { $0 + ($1.watts ?? 0) * $1.dt }

        // Quem impediu o Mac de dormir
        var holdSecs: [Int: [String: Double]] = [:]
        var holdNames: [Int: [String: Set<String>]] = [:]
        if n > 0, let st = db.prepare("SELECT k,proc,type,name,secs FROM holds WHERE session=?") {
            st.bind(session.id)
            while st.next() {
                guard idxOfK[Int(st.int(0))] != nil, let procId = st.optInt(1), let gi = groupOf[procId] else { continue }
                let type = st.text(2) ?? "?"
                holdSecs[gi, default: [:]][type, default: 0] += st.double(4)
                if let nm = st.text(3), !nm.isEmpty { holdNames[gi, default: [:]][type, default: []].insert(nm) }
            }
        }

        // 4. Métricas por grupo
        // Em gravações curtas os limites encolhem pra continuar fazendo sentido.
        let minStreak = min(settings.minStreakSec, max(10, windowSec * 0.3))
        var stats: [GroupStat] = []
        for gi in 0..<G {
            let isResid = gi == residualIndex
            if isResid && !hasResid { continue }
            let series = cpu[gi]
            let memSeries = mem[gi]
            if series == nil && memSeries == nil && holdSecs[gi] == nil { continue }
            let members = isResid ? [] : gMembers[gi]
            let identity = makeIdentity(members, key: isResid ? "_residual" : gKeys[gi], grouping: grouping, isResidual: isResid, memberCPU: memberCPU)
            var s = GroupStat(id: identity.key, identity: identity)

            // vivo em quais instantes
            var alive = [Bool](repeating: isResid, count: n)
            if !isResid && n > 0 {
                for p in members {
                    let lo = lowerBound(tArr, p.first - 0.001)
                    let hi = upperBound(tArr, p.last + 0.001) - 1
                    if lo <= hi { for i in lo...hi { alive[i] = true } }
                }
            }

            var cpuSec = 0.0, aliveSec = 0.0, peak = 0.0
            var activeTicks = 0, aliveTicks = 0
            var streakDur = 0.0, streakCPU = 0.0, longest = 0.0, sustained = 0.0
            var prevK = Int.min
            var pctSeries = [Double](repeating: 0, count: n)
            func closeStreak() {
                if streakDur >= minStreak { sustained += streakCPU }
                longest = max(longest, streakDur)
                streakDur = 0
                streakCPU = 0
            }
            for i in 0..<n {
                let tk = ticks[i]
                let c = series?[i] ?? 0
                let pct = tk.dt > 0 ? c / tk.dt * 100 : 0
                pctSeries[i] = pct
                if alive[i] || c > 0 { aliveSec += tk.dt; aliveTicks += 1 }
                cpuSec += c
                peak = max(peak, pct)
                let contiguous = tk.k == prevK + 1 && tk.dt <= interval * 3
                prevK = tk.k
                if !contiguous { closeStreak() }
                if pct >= settings.busyPct {
                    activeTicks += 1
                    streakDur += tk.dt
                    streakCPU += c
                } else {
                    closeStreak()
                }
            }
            closeStreak()

            s.cpuSec = cpuSec
            s.aliveSec = aliveSec
            s.avgPctWindow = windowSec > 0 ? cpuSec / windowSec * 100 : 0
            s.avgPctAlive = aliveSec > 0 ? cpuSec / aliveSec * 100 : 0
            s.activeRatio = aliveTicks > 0 ? Double(activeTicks) / Double(aliveTicks) : 0
            s.longestStreakSec = longest
            s.sustainedCpuSec = sustained
            s.peakPct = peak
            s.gpuSec = gpu[gi]
            s.wakeupsPerSec = (wakeMeasured[gi] && aliveSec > 0) ? wake[gi] / aliveSec : nil

            let unmeasured = max(0, cpuSec - energyCPU[gi])
            s.energyJ = energy[gi] + unmeasured * jPerCpuSec
            s.energyEstimated = unmeasured > cpuSec * 0.2
            if hasWatts && macJ > 0 { s.energyShareOfMac = s.energyJ / macJ }

            if let ms = memSeries {
                var vals: [(t: Double, b: Double)] = []
                for i in 0..<n where ms[i] > 0 { vals.append((ticks[i].t, ms[i])) }
                if !vals.isEmpty {
                    s.memAvg = vals.reduce(0) { $0 + $1.b } / Double(vals.count)
                    s.memPeak = vals.map(\.b).max()
                    if let f = vals.first, let l = vals.last, l.t - f.t >= 600 { s.memGrowth = l.b - f.b }
                }
            }
            if series != nil { s.series = downsample(pctSeries, to: 120) }

            if let hs = holdSecs[gi] {
                s.holds = hs.map {
                    HoldStat(type: $0.key, seconds: min($0.value, windowSec),
                             names: SleepHolds.describe(Array(holdNames[gi]?[$0.key] ?? []).sorted()))
                }.sorted { $0.seconds > $1.seconds }
            }

            s.score = sustained + (cpuSec - sustained) * 0.35 + s.gpuSec * 0.8 + (wakeMeasured[gi] ? wake[gi] * 0.0002 : 0)
            s.pattern = classify(s, windowSec: windowSec)

            if !isResid {
                var byKey: [String: (name: String, pids: Int, cpu: Double, memSum: Double, memN: Int)] = [:]
                for p in members {
                    let key = (p.path ?? p.name) + "|" + (p.args ?? "")
                    var e = byKey[key] ?? (name: p.args ?? p.name, pids: 0, cpu: 0, memSum: 0, memN: 0)
                    e.pids += 1
                    e.cpu += memberCPU[p.id] ?? 0
                    if let mm = memberMem[p.id] { e.memSum += mm.sum; e.memN += mm.n }
                    byKey[key] = e
                }
                s.members = byKey.map {
                    MemberStat(id: $0.key, name: $0.value.name, pidCount: $0.value.pids, cpuSec: $0.value.cpu,
                               memAvg: $0.value.memN > 0 ? $0.value.memSum / Double($0.value.memN) : nil)
                }.sorted { $0.cpuSec > $1.cpuSec }
                s.pidCount = members.count
            }
            stats.append(s)
        }

        let totalScore = stats.reduce(0) { $0 + $1.score }
        for i in stats.indices {
            stats[i].share = totalScore > 0 ? stats[i].score / totalScore : 0
            if let sh = stats[i].energyShareOfMac, sh >= 0.005, sh < 0.9, !stats[i].identity.isResidual {
                stats[i].batteryGainPct = sh / (1 - sh) * 100
            }
        }
        stats.sort { $0.score > $1.score }

        // 5. Bateria e consumo
        var bs = BatterySummary()
        bs.hasBattery = ticks.contains { $0.batt != nil }
        bs.onBatterySec = ticks.filter(\.onBatt).reduce(0) { $0 + $1.dt }
        bs.startPct = ticks.first?.batt
        bs.endPct = ticks.last?.batt
        bs.avgWatts = weightedAvg(ticks.compactMap { t in t.watts.map { ($0, t.dt) } })
        bs.avgWattsOnBattery = weightedAvg(ticks.filter(\.onBatt).compactMap { t in t.watts.map { ($0, t.dt) } })
        bs.peakWatts = ticks.compactMap(\.watts).max()
        bs.energyWh = hasWatts ? macJ / 3600 : nil
        var drop = 0.0
        var stretchStart: Double?
        var prevB: Double?
        for tk in ticks {
            if tk.onBatt, let b = tk.batt {
                if stretchStart == nil { stretchStart = b }
                prevB = b
            } else {
                if let s0 = stretchStart, let pb = prevB { drop += max(0, s0 - pb) }
                stretchStart = nil
                prevB = nil
            }
        }
        if let s0 = stretchStart, let pb = prevB { drop += max(0, s0 - pb) }
        bs.drop = drop
        let hrs = bs.onBatterySec / 3600
        if hrs >= 0.15 && drop >= 2 {
            bs.dropPerHour = drop / hrs
            bs.autonomyHours = 100 / (drop / hrs)
            bs.autonomyBasis = "pela queda real da bateria nesse período"
        } else if let w = bs.avgWattsOnBattery ?? bs.avgWatts, w > 0, let wh = session.batteryWh {
            bs.autonomyHours = wh / w
            bs.autonomyBasis = "pelo consumo médio de \(Fmt.watts(w)) numa bateria de ~\(Int(wh.rounded())) Wh"
        }

        // 6. Linha do tempo (até ~400 pontos)
        var timeline: [TickPoint] = []
        let step = max(1, n / 400)
        var i = 0
        while i < n {
            let j = min(n, i + step)
            let slice = ticks[i..<j]
            let busyVals = slice.compactMap(\.busy)
            let wVals = slice.compactMap(\.watts)
            let last = slice[slice.index(before: slice.endIndex)]
            timeline.append(TickPoint(id: i, date: Date(timeIntervalSince1970: last.t),
                                      busyPct: busyVals.isEmpty ? nil : busyVals.reduce(0, +) / Double(busyVals.count),
                                      watts: wVals.isEmpty ? nil : wVals.reduce(0, +) / Double(wVals.count),
                                      battery: last.batt, onBattery: last.onBatt))
            i = j
        }

        let start = Date(timeIntervalSince1970: (ticks.first?.t ?? session.started.timeIntervalSince1970) - (ticks.first?.dt ?? 0))
        let end = Date(timeIntervalSince1970: ticks.last?.t ?? session.started.timeIntervalSince1970)
        return Report(session: session, filter: filter, start: start, end: end, windowSec: windowSec, tickCount: n,
                      ncpu: session.ncpu > 0 ? session.ncpu : MacInfo.ncpu,
                      avgBusyPct: weightedAvg(ticks.compactMap { t in t.busy.map { ($0, t.dt) } }),
                      maxThermal: ticks.map(\.thermal).max() ?? 0, maxPressure: ticks.map(\.pressure).max() ?? 0,
                      battery: bs, timeline: timeline, groups: stats, jPerCpuSec: jPerCpuSec, settings: settings)
    }

    // MARK: - Agrupamento

    static func groupKey(_ p: ProcRow, _ grouping: Grouping) -> String {
        let path = p.path ?? p.name
        switch grouping {
        case .processo:
            return path
        case .app:
            if let a = AppCatalog.shared.outermostAppPath(path) { return "app:" + a }
            if let rp = p.rpath, isHelperLike(path), let a = AppCatalog.shared.outermostAppPath(rp) { return "app:" + a }
            return path
        }
    }

    /// Serviços XPC e extensões são cobrados do app que os usa (ex.: WebContent do Safari).
    static func isHelperLike(_ path: String) -> Bool {
        path.contains(".xpc/") || path.contains("/XPCServices/") || path.contains(".appex/") || path.contains("/PlugIns/")
    }

    private static func makeIdentity(_ members: [ProcRow], key: String, grouping: Grouping, isResidual: Bool, memberCPU: [Int64: Double]) -> GroupIdentity {
        if isResidual || members.isEmpty {
            return GroupIdentity(key: key, displayName: "Kernel e processos de vida curta", mainName: "_residual", path: nil, appPath: nil,
                                 appName: nil, bundleId: nil, isAppGroup: false, names: [], uids: [], responsibleApps: [], commands: [], isResidual: true)
        }
        let cat = AppCatalog.shared
        let main = members.max { (memberCPU[$0.id] ?? 0) < (memberCPU[$1.id] ?? 0) } ?? members[0]
        var appPath: String? = main.path.flatMap { cat.outermostAppPath($0) }
        if appPath == nil, grouping == .app, let rp = main.rpath, let p = main.path, isHelperLike(p) {
            appPath = cat.outermostAppPath(rp)
        }
        let app = appPath.flatMap { cat.appInfo(appPath: $0) }
        var cpuByName: [String: Double] = [:]
        for m in members { cpuByName[m.name, default: 0] += memberCPU[m.id] ?? 0 }
        let names = cpuByName.sorted { $0.value > $1.value }.map(\.key)
        var resp = Set<String>()
        for m in members {
            guard let rp = m.rpath else { continue }
            let n = cat.outermostAppPath(rp).flatMap { cat.appInfo(appPath: $0)?.name } ?? (rp as NSString).lastPathComponent
            if n != app?.name { resp.insert(n) }
        }
        var cmdCPU: [String: Double] = [:]
        for m in members { if let a = m.args { cmdCPU[a, default: 0] += memberCPU[m.id] ?? 0 } }
        let isAppGroup = grouping == .app && app != nil
        return GroupIdentity(key: key, displayName: isAppGroup ? app!.name : main.name, mainName: main.name, path: main.path,
                             appPath: appPath, appName: app?.name, bundleId: app?.bundleId, isAppGroup: isAppGroup, names: names,
                             uids: Set(members.map(\.uid)), responsibleApps: resp.sorted(),
                             commands: cmdCPU.sorted { $0.value > $1.value }.map(\.key), isResidual: false)
    }

    static func classify(_ s: GroupStat, windowSec: Double) -> Pattern {
        let small = min(10, max(1, windowSec * 0.05))
        if s.cpuSec < small && s.gpuSec < small { return .leve }
        if s.longestStreakSec >= min(120, max(20, windowSec * 0.5)) && s.sustainedShare >= 0.5 { return .continuo }
        if s.activeRatio >= 0.2 && s.cpuSec >= min(20, max(2, windowSec * 0.1)) { return .frequente }
        if s.gpuSec >= min(60, windowSec * 0.2) && s.gpuSec / max(s.aliveSec, 1) >= 0.05 { return .frequente }
        return .picos
    }

    // MARK: - Utilidades

    private static func weightedAvg(_ pairs: [(Double, Double)]) -> Double? {
        let w = pairs.reduce(0) { $0 + $1.1 }
        guard w > 0 else { return nil }
        return pairs.reduce(0) { $0 + $1.0 * $1.1 } / w
    }

    static func downsample(_ v: [Double], to m: Int) -> [Double] {
        guard v.count > m, m > 0 else { return v }
        let step = Double(v.count) / Double(m)
        return (0..<m).map { i in
            let a = Int(Double(i) * step)
            let b = min(v.count, max(a + 1, Int(Double(i + 1) * step)))
            let slice = v[a..<b]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    private static func lowerBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] < x { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    private static func upperBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let mid = (lo + hi) / 2; if a[mid] <= x { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}
