import SwiftUI
import WhoopScores

/// Kleur voor slaap (zelfde als de slaapring op Vandaag).
private let sleepColor = Theme.hex(0x8FA8C8)

private func clock(_ d: Date) -> String { SleepAlarm.clock(d) }
private func hm(_ m: Double) -> String { SleepPlanner.hm(m) }

/// Uren/minuten na middernacht als Date (vandaag), voor een DatePicker.
private func minuteBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
    Binding(
        get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(get()) * 60) },
        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); set((c.hour ?? 0) * 60 + (c.minute ?? 0)) })
}

// MARK: kaart op Vandaag

/// "Vannacht": aanbevolen bedtijd, tijd in bed en de wekker. Tik voor de slaapplanner.
struct TonightCard: View {
    @EnvironmentObject var alarm: SleepAlarm
    @EnvironmentObject var scores: ScoreModel
    var index = 0

    var body: some View {
        let p = alarm.plan()
        let rule = alarm.nextRule
        let on = alarm.schedule.enabled && rule.enabled
        NavigationLink { SleepPlannerView() } label: {
            Card(title: "Vannacht", index: index) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("BEDTIJD", systemImage: "moon.zzz.fill").font(Theme.label).tracking(1.5).foregroundStyle(sleepColor)
                        Text(clock(p.bedtime)).font(Theme.number(32)).monospacedDigit()
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Text(hm(p.inBedMin)).font(.subheadline.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(Capsule().stroke(Theme.line, lineWidth: 1.5))
                        Text("IN BED").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 4)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("WEKKER", systemImage: on ? "alarm.fill" : "alarm").font(Theme.label).tracking(1.5)
                            .foregroundStyle(on ? Theme.accent : Theme.zones[3].color)
                        Text(clock(p.wake)).font(Theme.number(32)).monospacedDigit()
                    }
                }
                Capsule().fill(LinearGradient(colors: [sleepColor.opacity(0.5), sleepColor, Theme.accent.opacity(on ? 0.9 : 0.3)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6).padding(.vertical, 4)
                HStack {
                    Text("\(Int(p.goal.fraction * 100))% van \(hm(p.need.total)) slaapbehoefte")
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Text(on ? rule.mode.title.uppercased() : "WEKKER UIT").font(Theme.label).tracking(1.5)
                        .foregroundStyle(on ? Theme.accent : Theme.zones[3].color)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
                .font(.footnote)
            }
        }
        .buttonStyle(.plain)
        .onAppear { alarm.rearm() }
    }
}

// MARK: slaapplanner

struct SleepPlannerView: View {
    @EnvironmentObject var alarm: SleepAlarm
    @EnvironmentObject var scores: ScoreModel
    @EnvironmentObject var ble: BLEManager

    var body: some View {
        let p = alarm.plan()
        let next = alarm.schedule.nextWake(after: Date())
        ScrollView {
            VStack(spacing: Theme.gap) {
                headline(p, next: next)
                goalPicker
                Card(title: "Planning", index: 1) {
                    PlanTimeline(plan: p, window: alarm.usualWindow, smart: next.rule.mode != .exact && alarm.schedule.enabled)
                }
                needCard(p)
                alarmCard(p, next: next)
                bandCard
                Text("Slaapbehoefte en herstel zijn eigen berekeningen op basis van je banddata, geen officiële Whoop-waarden.")
                    .font(.caption).foregroundStyle(Theme.muted).padding(.top, 4)
            }
            .padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Slaapplanner")
        .onAppear { alarm.rearm() }
    }

    // MARK: kop

    private func headline(_ p: TonightPlan, next: (date: Date, rule: AlarmRule)) -> some View {
        let now = Date()
        let pct = Int(p.goal.fraction * 100)
        let late = p.bedtime < now
        // Wat nog haalbaar is als de bedtijd al voorbij is.
        let left = max(0, (p.wake.timeIntervalSince(now) / 60 - p.latencyMin) * p.efficiency / 100)
        let reach = p.need.total > 0 ? Int(min(100, 100 * left / p.need.total)) : 0
        let cal = Calendar.current
        let workday = !cal.isDateInWeekend(next.date)
        let wakeMin = cal.component(.hour, from: next.date) * 60 + cal.component(.minute, from: next.date)
        return VStack(spacing: 12) {
            Image(systemName: late ? "exclamationmark.circle" : "moon.stars.fill")
                .font(.system(size: 30)).foregroundStyle(late ? Theme.zones[3].color : sleepColor)
                .frame(width: 60, height: 60).overlay(Circle().stroke(Theme.line, lineWidth: 1.5))
            Group {
                if late {
                    Text("Je bedtijd van \(clock(p.bedtime)) is voorbij. Ga zo snel mogelijk: nu haal je nog ~\(reach)% van je slaapbehoefte vóór \(clock(p.wake)).")
                } else {
                    Text("Ga om **\(clock(p.bedtime))** naar bed om **\(pct)%** van je slaapbehoefte te halen vóór \(clock(p.wake)).")
                }
            }
            .font(.title3).multilineTextAlignment(.center)
            if workday && wakeMin > alarm.workStart - 30 {
                Label("Je werkt om \(SleepAlarm.clock(minutes: alarm.workStart)); deze wektijd is krap.", systemImage: "briefcase")
                    .font(.footnote).foregroundStyle(Theme.zones[3].color)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }

    private var goalPicker: some View {
        VStack(spacing: 8) {
            Text("MORGEN WIL IK").font(Theme.label).tracking(2).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(SleepGoal.allCases, id: \.self) { g in
                    let sel = alarm.goal == g
                    Button { withAnimation(Theme.spring) { alarm.goal = g } } label: {
                        VStack(spacing: 2) {
                            Text(g.title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                            Text("\(Int(g.fraction * 100))%").font(Theme.label).foregroundStyle(sel ? Theme.accent : Theme.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(sel ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(sel ? Theme.accent : Theme.line, lineWidth: sel ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: slaapbehoefte

    private func needCard(_ p: TonightPlan) -> some View {
        Card(title: "Slaapbehoefte vannacht", index: 2) {
            needRow("Basis", p.need.healthy, sign: "")
            needRow("Belasting vandaag", p.need.strain, sign: "+")
            needRow(p.debtMin > 0 ? "Slaapschuld (\(hm(p.debtMin)))" : "Slaapschuld", p.need.debt, sign: "+")
            needRow("Dutjes vandaag", -p.need.naps, sign: "−")
            Divider().overlay(Theme.line)
            HStack {
                Text("Totaal").font(.subheadline.weight(.semibold))
                Spacer()
                Text(hm(p.need.total)).font(Theme.number(20)).monospacedDigit()
            }
            Text("Doel \(Int(p.goal.fraction * 100))%: \(hm(p.goalSleepMin)) slaap. Met \(Int(p.efficiency.rounded()))% slaapefficiëntie en \(Int(p.latencyMin)) min inslapen is dat \(hm(p.inBedMin)) in bed.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private func needRow(_ label: String, _ v: Double, sign: String) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(v.rounded() == 0 ? "–" : "\(sign)\(hm(abs(v)))").font(.subheadline).monospacedDigit()
                .foregroundStyle(v.rounded() == 0 ? Theme.muted : Theme.text)
        }
    }

    // MARK: wekker

    private func alarmCard(_ p: TonightPlan, next: (date: Date, rule: AlarmRule)) -> some View {
        let override = alarm.schedule.override != nil && alarm.schedule.override?.day == DayStore.dayFmt.string(from: next.date)
        return Card(title: "Wekker", index: 3) {
            Toggle(isOn: $alarm.schedule.enabled) {
                Label("Wekker aan", systemImage: "alarm.fill")
            }
            .tint(Theme.accent)
            Divider().overlay(Theme.line)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))).font(.subheadline.weight(.semibold))
                    Text(override ? "Alleen deze ochtend" : "Volgens je schema").font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                DatePicker("", selection: minuteBinding(get: { next.rule.minutes },
                                                        set: { alarm.setOverride(minutes: $0, mode: next.rule.mode) }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(AlarmMode.allCases, id: \.self) { m in
                    ModeChip(mode: m, selected: next.rule.mode == m) { alarm.setOverride(minutes: next.rule.minutes, mode: m) }
                }
            }
            Text(next.rule.mode.explanation).font(.footnote).foregroundStyle(Theme.muted)
            if override {
                Button("Terug naar schema") {
                    var s = alarm.schedule; s.override = nil; alarm.schedule = s
                }
                .font(.footnote)
            }
            if alarm.schedule.enabled {
                if let s = alarm.phoneStatus { Label(s, systemImage: "iphone").font(.footnote).foregroundStyle(Theme.muted) }
                if let s = alarm.progress { Label(s, systemImage: "waveform.path.ecg").font(.footnote).foregroundStyle(Theme.accent) }
            }
            NavigationLink { AlarmScheduleView() } label: {
                HStack {
                    Label("Wekkerschema", systemImage: "calendar")
                    Spacer()
                    Text("ma–vr \(SleepAlarm.clock(minutes: alarm.schedule.weekday.minutes)) · za–zo \(SleepAlarm.clock(minutes: alarm.schedule.weekend.minutes))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .buttonStyle(.plain).padding(.top, 4)
            if !SleepAlarm.hasSystemAlarm {
                Text("Deze iPhone kan geen echte wekker vanuit een app zetten (pas vanaf iOS 26). Je krijgt een melding met geluid; die klinkt niet in stille modus of met een focus aan.")
                    .font(.caption).foregroundStyle(Theme.zones[3].color)
            }
            if next.rule.mode != .exact {
                Text("Slim wekken werkt alleen als de app 's nachts met de band verbonden blijft. Valt de verbinding weg, dan gaat de wekker op de ingestelde tijd.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var bandCard: some View {
        Card(title: "Band laten trillen · experimenteel", index: 4) {
            Toggle(isOn: $alarm.bandHaptics) { Label("Wekker ook op de band", systemImage: "applewatch.radiowaves.left.and.right") }
                .tint(Theme.accent)
            Button {
                alarm.testBand()
            } label: {
                Label("Test: laat de band over 30 s trillen", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(Theme.accent)
            .disabled(ble.state != .connected)
            if let s = alarm.bandStatus { Text(s).font(.footnote).foregroundStyle(Theme.accent) }
            Text("Het wekkercommando komt van de Whoop 4.0 en is op jouw band nog niet bevestigd. De band antwoordt met ‘ok’ of ‘niet ondersteund’; dat zie je hierboven. Een commando om de bandwekker te wissen is niet bekend: uitzetten zet hem een jaar vooruit. Zet je in de Whoop-app ook een wekker, dan kan die deze overschrijven. De iPhone-wekker blijft altijd aan als vangnet.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }
}

/// Knop voor een wekkermodus.
struct ModeChip: View {
    let mode: AlarmMode
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(mode.title, systemImage: mode.icon)
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .background(selected ? Theme.accent.opacity(0.14) : Theme.cardHi, in: Capsule())
                .overlay(Capsule().stroke(selected ? Theme.accent.opacity(0.6) : Theme.line))
        }
        .buttonStyle(.plain)
    }
}

// MARK: tijdlijn

/// Balk van bedtijd tot wektijd, met je gebruikelijke slaapvenster eronder en het slimme venster.
struct PlanTimeline: View {
    let plan: TonightPlan
    let window: (bed: Int, wake: Int, measured: Bool)
    var smart = false

    var body: some View {
        let cal = Calendar.current
        let wakeDay = cal.startOfDay(for: plan.wake)
        let usualWake = wakeDay.addingTimeInterval(Double(window.wake) * 60)
        let usualBed = usualWake.addingTimeInterval(-Double((window.wake - window.bed + 1440) % 1440) * 60)
        let lo = min(plan.bedtime, usualBed).addingTimeInterval(-1800)
        let hi = max(plan.wake, usualWake).addingTimeInterval(1800)
        let span = max(1, hi.timeIntervalSince(lo))
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(clock(plan.bedtime)).font(Theme.number(22)).monospacedDigit()
                    Text("NAAR BED").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(clock(plan.wake)).font(Theme.number(22)).monospacedDigit()
                    Text("WAKKER").font(Theme.label).tracking(1.5).foregroundStyle(Theme.muted)
                }
            }
            GeometryReader { g in
                let w = g.size.width
                let x = { (d: Date) in CGFloat(d.timeIntervalSince(lo) / span) * w }
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Theme.line).frame(height: 6).offset(y: 9)
                    if smart {
                        let s = plan.wake.addingTimeInterval(-SleepPlanner.smartWindowMin * 60)
                        RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.18))
                            .frame(width: max(2, x(plan.wake) - x(s)), height: 24).offset(x: x(s))
                    }
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [sleepColor.opacity(0.6), sleepColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, x(plan.wake) - x(plan.bedtime)), height: 24).offset(x: x(plan.bedtime))
                    Text(hm(plan.inBedMin)).font(.footnote.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.bg, in: Capsule()).overlay(Capsule().stroke(Theme.text.opacity(0.8), lineWidth: 1.5))
                        .position(x: (x(plan.bedtime) + x(plan.wake)) / 2, y: 12)
                    // gebruikelijk venster
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: max(2, x(usualWake) - x(usualBed)), height: 10).offset(x: x(usualBed), y: 34)
                }
            }
            .frame(height: 48)
            HStack(spacing: 14) {
                Label("In bed", systemImage: "square.fill").foregroundStyle(sleepColor)
                Label("\(window.measured ? "Jouw ritme" : "Ingesteld ritme") \(SleepAlarm.clock(minutes: window.bed))–\(SleepAlarm.clock(minutes: window.wake))",
                      systemImage: "square.dashed").foregroundStyle(Theme.muted)
                if smart { Label("Slim venster", systemImage: "square.fill").foregroundStyle(Theme.accent.opacity(0.7)) }
            }
            .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

// MARK: wekkerschema

struct AlarmScheduleView: View {
    @EnvironmentObject var alarm: SleepAlarm

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                Toggle(isOn: $alarm.schedule.enabled) { Label("Wekkerschema aan", systemImage: "alarm.fill") }
                    .tint(Theme.accent).padding(16)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                ruleCard("Ma · di · wo · do · vr", rule: $alarm.schedule.weekday, index: 1)
                ruleCard("Za · zo", rule: $alarm.schedule.weekend, index: 2)
                Card(title: "Je ritme", index: 3) {
                    timeRow("Gebruikelijke bedtijd", get: { alarm.usualBed }, set: { alarm.usualBed = $0 })
                    timeRow("Gebruikelijk opstaan", get: { alarm.usualWake }, set: { alarm.usualWake = $0 })
                    timeRow("Werk begint (ma–vr)", get: { alarm.workStart }, set: { alarm.workStart = $0 })
                    Text("Het ritme is de grijze stippellijn in de planner, tot er genoeg nachten gemeten zijn (vanaf 3 nachten rekent de app het zelf uit). De werktijd gebruikt de planner alleen om te waarschuwen als je wektijd krap is.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .padding()
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Wekkerschema")
    }

    private func ruleCard(_ title: String, rule: Binding<AlarmRule>, index: Int) -> some View {
        Card(title: title, index: index) {
            HStack {
                DatePicker("", selection: minuteBinding(get: { rule.wrappedValue.minutes }, set: { rule.wrappedValue.minutes = $0 }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
                Toggle("", isOn: rule.enabled).labelsHidden().tint(Theme.accent)
            }
            HStack(spacing: 6) {
                ForEach(AlarmMode.allCases, id: \.self) { m in
                    ModeChip(mode: m, selected: rule.wrappedValue.mode == m) { rule.wrappedValue.mode = m }
                }
            }
            Text(rule.wrappedValue.mode.explanation).font(.footnote).foregroundStyle(Theme.muted)
        }
        .opacity(rule.wrappedValue.enabled ? 1 : 0.55)
    }

    private func timeRow(_ label: String, get: @escaping () -> Int, set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            DatePicker("", selection: minuteBinding(get: get, set: set), displayedComponents: .hourAndMinute).labelsHidden()
        }
    }
}
