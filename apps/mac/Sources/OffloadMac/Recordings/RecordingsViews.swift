import OffloadImport
import SwiftUI

// Views only: every decision is in RecordingsImportModel and every string in RecordingsCopy.

/// Separate items drawn with dots between them (MetaItems), never one middle-dot string.
struct MetaItemsLine: View {
  let items: [String]
  var body: some View {
    if !items.isEmpty { CaptionLine(items.joined(separator: " · ")) }
  }
}

/// Screen 11's body above its buttons: the folder, what is in it, and why it cannot be read when it cannot.
public struct RecordingsScreenBody: View {
  @ObservedObject var model: RecordingsImportModel
  public init(model: RecordingsImportModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      if let folder = model.folder {
        Label(folder.lastPathComponent, systemImage: "folder")
          .textStyle(Tokens.TypeScale.label)
          .foregroundStyle(Theme.ink)
          .accessibilityIdentifier("recordings.folder")
      }
      MetaItemsLine(items: model.summaryItems)
      if let refusal = model.refusal {
        Text(refusal).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
      // The model's notice is drawn by the screen around this body (onboarding's notice line, or Settings), once.
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // The folder is read when the screen appears, off the main actor, never at launch.
    .task { await model.refresh() }
  }
}

/// Settings, Recordings: the folder, Import, and each import space with Remove imported data.
public struct RecordingsSettingsView: View {
  @ObservedObject var model: RecordingsImportModel
  public init(model: RecordingsImportModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s16) {
      Text(RecordingsCopy.settingsTitle).textStyle(Tokens.TypeScale.display).foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
      Text(RecordingsCopy.settingsHelp).textStyle(Tokens.TypeScale.body).foregroundStyle(Theme.ink2)
        .fixedSize(horizontal: false, vertical: true)
      RecordingsScreenBody(model: model)
      if model.isOffered {
        HStack(spacing: Tokens.Space.s12) {
          Button(OnboardingCopy.chooseFolder) { Task { await model.chooseFolder() } }
            .buttonStyle(SecondaryButtonStyle())
          Button(OnboardingCopy.importTitle) { Task { await model.startImport() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isImporting)
        }
      } else {
        Text(RecordingsCopy.needsSending).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
      if let notice = model.notice, notice != model.refusal, notice != RecordingsCopy.needsSending {
        Text(notice).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.ink2)
      }
      if !model.progressItems.isEmpty { MetaItemsLine(items: model.progressItems) }
      Divider()
      if model.imports.isEmpty {
        Text(RecordingsCopy.noImports).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.muted)
      }
      ForEach(model.imports, id: \.space.id) { record in
        HStack(spacing: Tokens.Space.s12) {
          MetaItemsLine(items: RecordingsCopy.pill(record, timeZone: model.timeZone))
          Spacer()
          Button(RecordingsCopy.removeImported) { Task { await model.remove(record) } }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(([RecordingsCopy.removeImported] + RecordingsCopy.pill(record, timeZone: model.timeZone)).joined(separator: ", "))
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Tokens.Space.s24)
    .frame(minWidth: 520, minHeight: 360, alignment: .topLeading)
    .background(Theme.paper)
    .preferredColorScheme(.light)
  }
}

/// The floating progress panel: "reading file 3 of 12", then "done · 1,284 moments read", and any warnings.
public struct ImportPanelView: View {
  @ObservedObject var model: RecordingsImportModel
  public init(model: RecordingsImportModel) { self.model = model }

  public var body: some View {
    VStack(alignment: .leading, spacing: Tokens.Space.s8) {
      Text(RecordingsCopy.panelTitle).textStyle(Tokens.TypeScale.title).foregroundStyle(Theme.chromeInk)
      if model.progressItems.isEmpty {
        Text(RecordingsCopy.starting).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      } else {
        CaptionLine(model.progressItems.joined(separator: " · "), onChrome: true)
      }
      ForEach(Array(model.warnings.enumerated()), id: \.offset) { pair in
        Text(pair.element).textStyle(Tokens.TypeScale.callout).foregroundStyle(Theme.chromeMute)
      }
      HStack {
        Spacer()
        Button(RecordingsCopy.close) { model.closePanel() }
          .buttonStyle(SecondaryButtonStyle())
      }
    }
    .padding(Tokens.Space.s16)
    .frame(width: 340, alignment: .leading)
    .background(Theme.chrome)
    // The panel's line changes while the person works elsewhere: VoiceOver hears each change.
    .onChange(of: model.announcements) { _, _ in
      guard let line = model.announcement else { return }
      AccessibilityNotification.Announcement(line).post()
    }
  }
}

/// The Settings window. Only Recordings exists so far; the other sections land with their slices.
public struct OffloadSettingsView: View {
  @ObservedObject var app: AppModel
  public init(app: AppModel) { self.app = app }

  public var body: some View {
    if let recordings = app.recordings {
      RecordingsSettingsView(model: recordings)
    } else {
      Text(RecordingsCopy.noImports).padding(Tokens.Space.s24)
    }
  }
}
