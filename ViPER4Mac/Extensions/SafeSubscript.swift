//ViPER4Mac/Extensions/SafeSubscript.swift
import Foundation

extension Array {
  subscript(safe index: Int) -> Element? {
    guard index >= 0 && index < count else { return nil }
    return self[index]
  }
}
