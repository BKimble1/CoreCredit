//
//  NotificationSettingsView.swift
//  CoreCredit
//

import SwiftData
import SwiftUI
import UIKit

/// Where reminders are switched on, tuned, and — importantly — where the system permission is
/// actually asked for.
///
/// # Permission is requested here, in context
///
/// Nothing in CoreCredit asks for notification permission at launch. iOS shows that prompt exactly
/// once, and spending it before the owner knows what the reminders are for permanently costs the
/// feature. So the prompt appears when this screen's master switch is turned on (or when the
/// explicit "Allow reminders" button is tapped), by way of
/// `ReminderCoordinator.requestAuthorizationIfNeeded()`. Opening the screen only *reads* the
/// current status, which never prompts.
///
/// # A refusal is stated, not papered over
///
/// When permission is denied, the switch stays usable but the screen says plainly that no alerts
/// will arrive and offers the one thing that can fix it — a jump to the app's page in the Settings
/// app. It never implies reminders are working when they are not.
///
/// # Every change reschedules, and both failures and omissions are visible
///
/// Any edit here saves the profile and then rebuilds the whole queue through
/// `ReminderCoordinator.requestRefresh(context:)`. If the notification centre refuses, `lastError`
/// is shown in an `ErrorBanner`. If the device's pending-notification limit meant some reminders
/// could not be queued, `lastRefresh` says how many — a reminder that silently failed to schedule
/// is worse than no reminder at all.
struct NotificationSettingsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [ShopProfile]
    @Query private var items: [CoreItem]

    @State private var errorMessage: String?
    @State private var testMessage: String?

    init() { }

    var body: some View {
        Form {
            if let errorMessage = errorMessage {
                Section {
                    ErrorBanner(message: errorMessage, onDismiss: { self.errorMessage = nil })
                        .listRowBackground(Color.clear)
                }
            }

            if let schedulingError = appEnvironment.reminders.lastError {
                Section {
                    ErrorBanner(
                        message: schedulingError,
                        retryTitle: "Try again",
                        onRetry: { refreshNow() },
                        onDismiss: { appEnvironment.reminders.clearError() }
                    )
                    .listRowBackground(Color.clear)
                }
            }

            if let profile = profiles.first {
                masterSection(profile)

                if profile.remindersEnabled {
                    permissionSection()
                    timingSection(profile)
                    dueSoonSection(profile)
                    followUpSection(profile)
                    weeklySummarySection(profile)
                    privacySection(profile)
                    testSection()
                }

                coverageSection(profile)
            } else {
                Section {
                    Text("Reminder settings become available once the shop profile has been "
                         + "created. Reopen this screen in a moment.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(A11y.Notifications.root)
        .task {
            // Reading the status never prompts — see `ReminderCoordinator.refreshAuthorization()`.
            await appEnvironment.reminders.refreshAuthorization()
        }
    }

    // MARK: - Master switch

    private func masterSection(_ profile: ShopProfile) -> some View {
        Section {
            Toggle(isOn: remindersEnabledBinding(profile)) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Remind me about core deadlines")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Alerts before a return window closes, and follow-ups on credits that "
                         + "have not arrived.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityIdentifier(A11y.Notifications.enable)
            .accessibilityLabel(Text("Remind me about core deadlines"))
            .accessibilityHint(Text("Turning this on asks this device for permission to send "
                                    + "notifications."))
        } header: {
            Text("Reminders")
        } footer: {
            Text("Reminders are scheduled on this device only. Nothing is sent to a server, and "
                 + "turning them off cancels every alert CoreCredit has queued.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Permission

    /// The truth about what this device will actually do, in the same place the switch lives.
    private func permissionSection() -> some View {
        let status = appEnvironment.reminders.authorization

        return Section {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: permissionSymbol(status))
                    .imageScale(.medium)
                    .foregroundStyle(permissionTint(status))
                    .accessibilityHidden(true)

                Text(status.explanation)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Permission"))
            .accessibilityValue(Text(status.explanation))

            if status == .notDetermined {
                Button {
                    requestPermission()
                } label: {
                    PrimaryButtonLabel("Allow reminders", systemImage: "bell.badge")
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(
                    EdgeInsets(
                        top: Spacing.s,
                        leading: Spacing.l,
                        bottom: Spacing.s,
                        trailing: Spacing.l
                    )
                )
                .accessibilityHint(Text("Shows this device's permission prompt for notifications."))
            }

            if status == .denied, let settingsURL = NotificationSettingsView.appSettingsURL {
                Link(destination: settingsURL) {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "arrow.up.forward.app")
                            .imageScale(.medium)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)

                        Text("Open the Settings app")
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: Spacing.s)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier(A11y.Notifications.openSettings)
                .accessibilityLabel(Text("Open the Settings app"))
                .accessibilityHint(Text("Opens CoreCredit's page in the Settings app, where "
                                        + "notifications can be turned back on."))
            }
        } header: {
            Text("Permission")
        } footer: {
            Text(permissionFooter(status))
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Time of day

    private func timingSection(_ profile: ShopProfile) -> some View {
        Section {
            DatePicker(selection: reminderTimeBinding(profile), displayedComponents: .hourAndMinute) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Time of day")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(timeText(profile))
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .datePickerStyle(.compact)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Time of day for reminders"))
            .accessibilityValue(Text(timeText(profile)))
        } header: {
            Text("When")
        } footer: {
            Text("Every reminder fires at this time. Pick a time the shop is open and someone is "
                 + "at the counter — a reminder whose moment has already passed is skipped rather "
                 + "than fired late.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Due soon

    private func dueSoonSection(_ profile: ShopProfile) -> some View {
        Section {
            ForEach(ShopProfile.dueSoonLeadDayChoices, id: \.self) { day in
                Toggle(isOn: leadDayBinding(profile, day: day)) {
                    Text(NotificationSettingsView.leadPhrase(day).capitalizedFirstLetter)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Palette.accent)
                .frame(minHeight: Spacing.minimumTapTarget)
                .accessibilityLabel(Text(NotificationSettingsView.leadPhrase(day)))
            }
        } header: {
            Text("Before the deadline")
        } footer: {
            Text("Pick as many as you want — each one is its own alert. You always get one on the "
                 + "morning a core is due, and a nudge each day it stays overdue, whatever is "
                 + "chosen here.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Follow-ups

    private func followUpSection(_ profile: ShopProfile) -> some View {
        Section {
            Stepper(value: awaitingCreditBinding(profile),
                    in: ShopProfile.minimumDelayDays...ShopProfile.maximumDelayDays) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Chase a missing credit after")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(NotificationSettingsView.dayPhrase(profile.awaitingCreditReminderDelayDays))
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Chase a missing credit after"))
            .accessibilityValue(
                Text(NotificationSettingsView.dayPhrase(profile.awaitingCreditReminderDelayDays))
            )

            Stepper(value: disputeFollowUpBinding(profile),
                    in: ShopProfile.minimumDelayDays...ShopProfile.maximumDelayDays) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Follow up a dispute after")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(NotificationSettingsView.dayPhrase(profile.disputeFollowUpReminderDelayDays))
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Follow up a dispute after"))
            .accessibilityValue(
                Text(NotificationSettingsView.dayPhrase(profile.disputeFollowUpReminderDelayDays))
            )
        } header: {
            Text("After a return")
        } footer: {
            Text("Counted from the day a core went back to the vendor, and from the day a short "
                 + "credit was recorded. Recording the credit cancels the chase straight away.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Weekly summary

    private func weeklySummarySection(_ profile: ShopProfile) -> some View {
        Section {
            Toggle(isOn: weeklySummaryBinding(profile)) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Weekly summary")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                    Text("One Monday morning alert counting the cores still open.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("Weekly summary"))
        } header: {
            Text("Weekly")
        } footer: {
            Text("Off unless you ask for it. It names no core, no vendor, and no amount — only how "
                 + "many are still outstanding.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Privacy

    private func privacySection(_ profile: ShopProfile) -> some View {
        Section {
            Toggle(isOn: showsDetailBinding(profile)) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Show item details in notifications")
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Adds the part, the amount, the vendor, and the bin to the alert text.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityIdentifier(A11y.Notifications.details)
            .accessibilityLabel(Text("Show item details in notifications"))

            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: "bell")
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(NotificationSettingsView.previewTitle(profile))
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(NotificationSettingsView.previewBody(profile))
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Example alert"))
            .accessibilityValue(
                Text(NotificationSettingsView.previewTitle(profile) + ". "
                     + NotificationSettingsView.previewBody(profile))
            )
        } header: {
            Text("What the alert says")
        } footer: {
            Text("Off by default. A banner can be read by anyone standing near the phone, and an "
                 + "unlocked screen is not the place for a vendor's name or a dollar figure. "
                 + "Whether this is on or off, a notification never carries anything beyond the "
                 + "core's identifier and a link back into the app.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Test

    private func testSection() -> some View {
        Section {
            Button {
                sendTestNotification()
            } label: {
                PrimaryButtonLabel("Send a test notification", systemImage: "bell.and.waves.left.and.right")
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.s, trailing: Spacing.l)
            )
            .accessibilityIdentifier(A11y.Notifications.test)
            .accessibilityHint(Text("Delivers one example alert about five seconds from now."))

            // The confirmation for an action the owner just took belongs in the app, not in a
            // second notification — see `ConfirmationBanner`. It sits directly under the button
            // that caused it and stays until it is dismissed.
            if let testMessage = testMessage {
                ConfirmationBanner(
                    message: testMessage,
                    systemImage: "bell.badge",
                    onDismiss: { self.testMessage = nil }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(
                    EdgeInsets(top: Spacing.s, leading: Spacing.l, bottom: Spacing.s, trailing: Spacing.l)
                )
            }
        } header: {
            Text("Check it works")
        } footer: {
            Text("The test alert names no core and changes nothing. Lock the screen after tapping "
                 + "to see it the way it will really arrive.")
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Coverage

    /// How many cores this setting can actually apply to, how many alerts are queued, and the one
    /// thing this app genuinely cannot do.
    private func coverageSection(_ profile: ShopProfile) -> some View {
        Section {
            LabeledValueRow("Open cores", value: String(remindableCount), symbol: "shippingbox")

            if let report = appEnvironment.reminders.lastRefresh {
                LabeledValueRow("Reminders queued",
                                value: String(report.scheduledCount),
                                symbol: "bell.badge")

                if report.droppedCount > 0 {
                    LabeledValueRow("Not queued",
                                    value: String(report.droppedCount),
                                    symbol: "exclamationmark.circle")
                }

                Text(report.summary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
            }
        } header: {
            Text("What is queued")
        } footer: {
            Text(coverageFooter(profile))
        }
        .listRowBackground(Palette.surface)
    }

    // MARK: - Bindings

    private func remindersEnabledBinding(_ profile: ShopProfile) -> Binding<Bool> {
        Binding(
            get: { profile.remindersEnabled },
            set: { newValue in setRemindersEnabled(newValue, profile: profile) }
        )
    }

    /// One switch per offered lead. Turning them all off is a legitimate answer: it means "only
    /// tell me on the day", which is what the due-today reminder already does.
    private func leadDayBinding(_ profile: ShopProfile, day: Int) -> Binding<Bool> {
        Binding(
            get: { profile.reminderDueSoonLeadDays.contains(day) },
            set: { isOn in
                var days = profile.reminderDueSoonLeadDays
                if isOn {
                    if !days.contains(day) { days.append(day) }
                } else {
                    days.removeAll { $0 == day }
                }
                profile.reminderDueSoonLeadDays = days
                saveAndRefresh(profile)
            }
        )
    }

    private func awaitingCreditBinding(_ profile: ShopProfile) -> Binding<Int> {
        Binding(
            get: { profile.awaitingCreditReminderDelayDays },
            set: { newValue in
                profile.awaitingCreditReminderDelayDays = NotificationSettingsView.clampDelay(newValue)
                saveAndRefresh(profile)
            }
        )
    }

    private func disputeFollowUpBinding(_ profile: ShopProfile) -> Binding<Int> {
        Binding(
            get: { profile.disputeFollowUpReminderDelayDays },
            set: { newValue in
                profile.disputeFollowUpReminderDelayDays = NotificationSettingsView.clampDelay(newValue)
                saveAndRefresh(profile)
            }
        )
    }

    private func weeklySummaryBinding(_ profile: ShopProfile) -> Binding<Bool> {
        Binding(
            get: { profile.weeklySummaryEnabled },
            set: { newValue in
                profile.weeklySummaryEnabled = newValue
                saveAndRefresh(profile)
            }
        )
    }

    private func showsDetailBinding(_ profile: ShopProfile) -> Binding<Bool> {
        Binding(
            get: { profile.showsDetailInNotifications },
            set: { newValue in
                profile.showsDetailInNotifications = newValue
                saveAndRefresh(profile)
            }
        )
    }

    /// The stored hour and minute, presented as a `Date` on an arbitrary day so `DatePicker` can
    /// edit it. Only the hour and minute components are ever written back.
    private func reminderTimeBinding(_ profile: ShopProfile) -> Binding<Date> {
        Binding(
            get: { reminderDate(profile) },
            set: { newValue in
                let components = calendar.dateComponents([.hour, .minute], from: newValue)
                profile.reminderHour = components.hour ?? profile.reminderHour
                profile.reminderMinute = components.minute ?? profile.reminderMinute
                saveAndRefresh(profile)
            }
        )
    }

    // MARK: - Actions

    /// Turning the switch on is the moment the owner has asked for reminders, so it is also the
    /// moment — and the only moment — that the system prompt is allowed to appear.
    private func setRemindersEnabled(_ newValue: Bool, profile: ShopProfile) {
        profile.remindersEnabled = newValue
        guard persist(profile) else { return }

        let reminders = appEnvironment.reminders
        let context = modelContext
        Task {
            if newValue, reminders.authorization == .notDetermined {
                await reminders.requestAuthorizationIfNeeded()
            }
            // Requested after the prompt has been answered, so a freshly granted permission is in
            // force by the time the queue is rebuilt.
            reminders.requestRefresh(context: context)
        }
    }

    private func requestPermission() {
        let reminders = appEnvironment.reminders
        let context = modelContext
        Task {
            await reminders.requestAuthorizationIfNeeded()
            reminders.requestRefresh(context: context)
        }
    }

    private func sendTestNotification() {
        let reminders = appEnvironment.reminders
        testMessage = nil
        Task {
            let sent = await reminders.sendTestNotification()
            if sent {
                testMessage = "A test notification is on its way — it should arrive in about "
                    + "five seconds."
            } else {
                // The reason is already in `reminders.lastError`, which the banner at the top of
                // this screen is showing. Saying it twice would be worse, not clearer.
                testMessage = nil
            }
        }
    }

    /// Rebuilds the queue without saving anything. Used by the error banner's retry.
    private func refreshNow() {
        appEnvironment.reminders.requestRefresh(context: modelContext)
    }

    /// Saves the edited profile, then rebuilds the queue.
    ///
    /// Saving already announces the change through `CoreItemChangeRelay`, so this second request is
    /// belt and braces rather than a second rebuild: `requestRefresh` replaces the pending one.
    private func saveAndRefresh(_ profile: ShopProfile) {
        guard persist(profile) else { return }
        refreshNow()
    }

    /// Saves the profile. Returns `false` — and shows why — when the store refused the write, so a
    /// caller does not go on to schedule alerts for a setting that was never stored.
    private func persist(_ profile: ShopProfile) -> Bool {
        do {
            try appEnvironment.itemService(modelContext).updateShopProfile(profile)
            errorMessage = nil
            return true
        } catch {
            errorMessage = NotificationSettingsView.message(for: error)
            return false
        }
    }

    // MARK: - Values

    private var calendar: Calendar { appEnvironment.dateProvider.calendar }

    private var now: Date { appEnvironment.dateProvider.now }

    /// Cores that can still be reminded about at all.
    private var remindableCount: Int {
        items.reduce(into: 0) { total, item in
            if item.status.isUnresolved { total += 1 }
        }
    }

    private func reminderDate(_ profile: ShopProfile) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        let hour = min(max(profile.reminderHour, 0), 23)
        let minute = min(max(profile.reminderMinute, 0), 59)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay)
            ?? startOfDay
    }

    private func timeText(_ profile: ShopProfile) -> String {
        reminderDate(profile).formatted(date: .omitted, time: .shortened)
    }

    private func coverageFooter(_ profile: ShopProfile) -> String {
        var text = "Reminders are built on this device from the dates in this ledger. "
        text += "CoreCredit has no connection to any vendor, so it cannot tell when a core is "
        text += "actually accepted or when a credit is actually issued — it only knows what has "
        text += "been recorded here. Credited and written-off cores are never scheduled, and a "
        text += "reminder whose moment has already passed is skipped instead of firing late. "

        if profile.remindersEnabled {
            text += "Editing a core rebuilds this queue straight away."
        } else {
            text += "Reminders are currently switched off, so nothing is queued."
        }
        return text
    }

    private func permissionSymbol(_ status: NotificationAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return "checkmark.circle"
        case .denied:
            return "exclamationmark.triangle"
        case .notDetermined, .unknown:
            return "questionmark.circle"
        }
    }

    /// Amber for "needs your attention", plain text colour otherwise. Red is reserved in this app
    /// for overdue and disputed money and is deliberately not borrowed here.
    private func permissionTint(_ status: NotificationAuthorizationStatus) -> Color {
        status.allowsScheduling ? Palette.textSecondary : Palette.accent
    }

    private func permissionFooter(_ status: NotificationAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "Until notifications are allowed for CoreCredit in the Settings app, no alert "
                + "will arrive — the ledger and its due dates still work, you just have to come "
                + "and look."
        case .notDetermined:
            return "CoreCredit has not shown the permission prompt yet. iOS only offers it once, "
                + "so it is asked for here rather than at launch."
        case .provisional:
            return "Quiet reminders arrive in Notification Centre without a banner or a sound."
        default:
            return "Reminders are delivered by this device. CoreCredit never sends them from a "
                + "server, and they carry no information beyond what is already in the ledger."
        }
    }

    // MARK: - Wording

    private static func leadPhrase(_ leadDays: Int) -> String {
        if leadDays <= 0 { return "on the day a core is due" }
        if leadDays == 1 { return "1 day before a deadline" }
        return String(leadDays) + " days before a deadline"
    }

    private static func dayPhrase(_ days: Int) -> String {
        days == 1 ? "1 day" : String(days) + " days"
    }

    /// The example alert, built from the same two rules the planner uses, so what is shown here is
    /// what will actually arrive.
    private static func previewTitle(_ profile: ShopProfile) -> String {
        profile.showsDetailInNotifications ? "Core return due Friday" : "Core return due soon"
    }

    private static func previewBody(_ profile: ShopProfile) -> String {
        guard profile.showsDetailInNotifications else {
            return "Open " + AppConfiguration.displayName + " to review this core."
        }
        return "Alternator (03-1887) \u{2014} "
            + Money(cents: 8_650).formatted(currencyCode: profile.currencyCode)
            + " to NAPA. Bin A3."
    }

    private static func clampDelay(_ days: Int) -> Int {
        if days < ShopProfile.minimumDelayDays { return ShopProfile.minimumDelayDays }
        if days > ShopProfile.maximumDelayDays { return ShopProfile.maximumDelayDays }
        return days
    }

    private static var appSettingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private static func message(for error: any Error) -> String {
        guard let localized = error as? any LocalizedError,
              let description = localized.errorDescription else {
            return error.localizedDescription
        }
        if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
            return description + " " + suggestion
        }
        return description
    }
}

// MARK: - Text helper

private extension String {

    /// Sentence-cases a phrase that was written to sit mid-sentence, without touching the rest of
    /// it — "3 days before a deadline" must not become "3 Days Before A Deadline".
    var capitalizedFirstLetter: String {
        guard let first = first else { return self }
        return String(first).uppercased() + String(dropFirst())
    }
}
