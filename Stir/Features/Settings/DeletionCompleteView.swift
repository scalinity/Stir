import SwiftUI

struct DeletionCompleteView: View {
    let state: HouseholdDataDeletionService.State?
    let onStartOver: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(Color.Stir.ember600)
                    .accessibilityHidden(true)
                Text("Your local data was removed")
                    .stirFont(.bodyLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                if state?.isCloudKit == true {
                    Text(state?.cloudExportedAt == nil
                         ? "iCloud deletion is waiting to sync. Keep Stir connected to iCloud; local removal alone does not confirm cloud deletion."
                         : "iCloud confirmed a successful export after the local deletion. Any older records that arrive later will also be removed.")
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.textSecondary)
                }
                Text("Your request to delete backend and analytics data has been submitted. These steps are separate and may take up to 30 days.")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.textSecondary)
                Text("Deleting data does not cancel an App Store subscription. Manage renewal in the App Store.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textSecondary)
                Link("Manage App Store subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                    .foregroundStyle(Color.Stir.ember600)
                Button("Start over", action: onStartOver)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.Stir.ember600)
                    .disabled(state?.lastEraseSavedAt == nil)
                Text("Starting over creates a new household on this device. It does not cancel the pending backend deletion request.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textSecondary)
                Link("Contact privacy@getstir.app", destination: URL(string: "mailto:privacy@getstir.app")!)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .padding(CGFloat.Stir.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.Stir.paper50)
    }
}
