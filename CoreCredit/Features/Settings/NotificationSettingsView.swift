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
/// # Every change reschedules, and failures are visible
///
/// Any edit here saves the profile and then rebuilds the whole queue through
/// `rescheduleAll(items:profile:)`. If the notification centre refuses, `lastError` is shown in an
/// `ErrorBanner` — a reminder that silently failed to schedule is worse than no reminder at all.
struct NotificationSettingsView: View {

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [ShopProfile]
    @Query private var items: [CoreItem]

    @State private var errorMessage: String?

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
                        onRetry: { rescheduleNow() },
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
                    previewSection(profile)
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

                    Text("One alert per core, before its return window closes.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)
            .frame(minHeight: Spacing.minimumTapTarget)
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

    // MARK: - Timing

    private func timingSection(_ profile: ShopProfile) -> some View {
        Section {
            Stepper(value: leadDaysBinding(profile),
                    in: NotificationSettingsView.minimumLeadDays...NotificationSettingsView.maximumLeadDays) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("How early")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                    Text(leadPhrase(profile.reminderLeadDays).capitalizedFirstLetter)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: Spacing.minimumTapTarget)
            .accessibilityLabel(Text("How early to be reminded"))
            .accessibilityValue(Text(leadPhrase(profile.reminderLeadDays)))

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
            Text("Pick a time the shop is open and someone is at the counter. A reminder whose "
                 + "moment has already passed is skipped rather than fired late.")
        }
        .listRowBackground(Palette.surface)
    }

    private func previewSection(_ profile: ShopProfile) -> some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: "bell")
                    .imageScale(.medium)
                    .foregroundStyle(Palette.textSecondary)
                    .accessibilityHidden(true)

                Text(previewSentence(profile))
                    .font(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minimumTapTarget, alignment: .leading)
            .padding(.vertical, Spacing.xs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(previewSentence(profile)))
        } header: {
            Text("What you'll get")
        }
        .listRowBackground(Palette.surface)
    }

    /// How many cores this setting can actually apply to right now. Closed cores and cores with no
    /// deadline are counted out, so the number is not quietly optimistic.
    private func coverageSection(_ profile: ShopProfile) -> some View {
        Section {
            LabeledValueRow("Cores with a deadline", value: String(remindableCount), symbol: "calendar")
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

    private func leadDaysBinding(_ profile: ShopProfile) -> Binding<Int> {
        Binding(
            get: { profile.reminderLeadDays },
            set: { newValue in
                profile.reminderLeadDays = NotificationSettingsView.clampLeadDays(newValue)
                saveAndReschedule(profile)
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
                saveAndReschedule(profile)
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
        let scheduled = items
        Task {
            if newValue, reminders.authorization == .notDetermined {
                await reminders.requestAuthorizationIfNeeded()
            }
            await reminders.rescheduleAll(items: scheduled, profile: profile)
        }
    }

    private func requestPermission() {
        let reminders = appEnvironment.reminders
        let scheduled = items
        guard let profile = profiles.first else { return }
        Task {
            await reminders.requestAuthorizationIfNeeded()
            await reminders.rescheduleAll(items: scheduled, profile: profile)
        }
    }

    private func rescheduleNow() {
        guard let profile = profiles.first else { return }
        let reminders = appEnvironment.reminders
        let scheduled = items
        Task {
            await reminders.rescheduleAll(items: scheduled, profile: profile)
        }
    }

    private func saveAndReschedule(_ profile: ShopProfile) {
        guard persist(profile) else { return }
        rescheduleNow()
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

    /// Cores that could receive a reminder: still open, and carrying a due date.
    private var remindableCount: Int {
        items.reduce(into: 0) { total, item in
            if item.status.isUnresolved && item.dueDate != nil { total += 1 }
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

    private func leadPhrase(_ leadDays: Int) -> String {
        if leadDays <= 0 { return "on the day a core is due" }
        if leadDays == 1 { return "1 day before a deadline" }
        return String(leadDays) + " days before a deadline"
    }

    /// "You'll be reminded 3 days before a deadline, at 8:00 AM."
    private func previewSentence(_ profile: ShopProfile) -> String {
        var sentence = "You'll be reminded "
        sentence += leadPhrase(profile.reminderLeadDays)
        sentence += ", at "
        sentence += timeText(profile)
        sentence += "."
        return sentence
    }

    private func coverageFooter(_ profile: ShopProfile) -> String {
        var text = "Only open cores with a return deadline can be reminded about. "
        text += "Credited and written-off cores are never scheduled, and a core whose reminder "
        text += "moment has already passed is skipped instead of firing immediately. "

        if profile.remindersEnabled {
            text += "Editing a core reschedules its own reminder straight away."
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

    private static func clampLeadDays(_ days: Int) -> Int {
        if days < minimumLeadDays { return minimumLeadDays }
        if days > maximumLeadDays { return maximumLeadDays }
        return days
    }

    /// Zero means "on the deadline itself", which is a legitimate choice for a shop that checks the
    /// board every morning.
    private static let minimumLeadDays = 0
    private static let maximumLeadDays = 30

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
