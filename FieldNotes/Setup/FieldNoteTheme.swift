import SwiftUI

/// Inspired by Night Green and Mars Brown in Sanzo Wada's A Dictionary of Color Combinations.
enum FieldNoteTheme {
    static let paper = Color(.notePaper)
    static let surface = Color(.noteSurface)
    static let mutedSurface = Color(.noteMutedSurface)
    static let ink = Color(.noteInk)
    static let mutedInk = Color(.noteMutedInk)
    static let clay = Color(.noteClay)

    // The waveform and labels over photos have fixed backgrounds in both appearances.
    static let evergreen = Color(.sRGB, red: 28 / 255, green: 42 / 255, blue: 32 / 255)
    static let leaf = Color(.sRGB, red: 196 / 255, green: 214 / 255, blue: 141 / 255)
}
