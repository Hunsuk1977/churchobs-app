// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// 앱 전체 글자 크기. macOS 기본(본문 13pt)보다 한두 단계 크게 — Claude 앱처럼 본문 15pt 기준
extension Font {
    static let uiTitle2 = Font.system(size: 20, weight: .regular)
    static let uiTitle3 = Font.system(size: 17, weight: .regular)
    static let uiHeadline = Font.system(size: 15, weight: .semibold)
    static let uiBody = Font.system(size: 15)
    static let uiCallout = Font.system(size: 14)
    static let uiCaption = Font.system(size: 12.5)
    static let uiCaption2 = Font.system(size: 11.5)
}

/// 번역: en.lproj/Localizable.strings에 있으면 영어, 없으면 원문(한국어).
/// 앱 언어는 시작할 때 정해진다 (로그인 화면의 언어 선택 → 앱 다시 시작)
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
