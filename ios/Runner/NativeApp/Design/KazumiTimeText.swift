//
//  KazumiTimeText.swift
//  Kazumi
//
//  界面上「今天 18:00」「10月30日」这类时间文案（Camo 4914）。
//
//  `Date.formatted(...)` 和 `.dateTime.hour().minute()` 都跟着**手机语言**走：
//  手机是英文，历史卡片上就漏出「6:00 PM」，跟整页中文拼在一起很扎眼。
//  所以这里统一用固定 zh_Hans_CN 的 `DateFormatter`，别再在页面里就地拼。
//

import Foundation

enum KazumiTimeText {
    /// `18:00`。24 小时制跟中文习惯一致。
    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// `10月30日`。
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// `今天 18:00` / `昨天 18:00` / `10月30日`。
    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天 \(clock(date))" }
        if calendar.isDateInYesterday(date) { return "昨天 \(clock(date))" }
        return day(date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        // 小时制跟手机的「24 小时制」开关走（Camo 4919，LP 4923）：开着写「18:00」，
        // 关着写「下午6:00」。模板 `j` 用 `Locale.current` 解出来是 `H` 还是 `h`，
        // 就是那台手机当前的偏好；语言本身仍旧固定中文，不跟着变。
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        formatter.dateFormat = template.contains("H") ? "H:mm" : "ah:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
