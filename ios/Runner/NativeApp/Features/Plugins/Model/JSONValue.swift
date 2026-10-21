//
//  JSONValue.swift
//  Kazumi
//
//  规则文件中的 body / query / headers 可以是任意 JSON 结构，Codable 的固定结构
//  无法覆盖，因此用一个轻量 JSON 树承载，并提供与 Dart jsonDecode/jsonEncode
//  等价的解析与序列化。
//

import Foundation

indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let bool as Bool:
            self = .bool(bool)
        case let int as Int:
            self = .int(int)
        case let double as Double:
            self = .double(double)
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            self = .double(number.doubleValue)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues(JSONValue.init(any:)))
        case let dictionary as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in dictionary {
                object[String(describing: key)] = JSONValue(any: item)
            }
            self = .object(object)
        default:
            self = .string(String(describing: value))
        }
    }

    /// 按「键值对数组」构造对象字面量（后写的键覆盖先写的键）。
    /// 注意：不能与 case `.object([String: JSONValue])` 同名，否则调用点会触发
    /// `ambiguous use of 'object'`，因此单独命名为 `dictionary`。
    static func dictionary(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(Dictionary(pairs, uniquingKeysWith: { _, latest in latest }))
    }

    /// 与 Dart `value == null` 对齐。
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 与 Dart `value.toString()` 对齐（null 视为空串），用于模板与查询参数。
    var toStringValue: String {
        stringValue ?? ""
    }

    /// 与 Dart `value.toString()` 对齐：数字不带无意义的尾零，null 为空串由调用方决定。
    var stringValue: String? {
        switch self {
        case .null: nil
        case .bool(let value): value ? "true" : "false"
        case .int(let value): String(value)
        case .double(let value):
            value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value): value
        case .array, .object:
            JSONValue.serialize(self, pretty: false)
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        case .bool(let value): value ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .string(let value): value.lowercased() == "true"
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    static func decode(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(any: any)
    }

    static func decode(_ string: String) throws -> JSONValue {
        guard let data = string.data(using: .utf8) else {
            throw ApiRuleFormatError(message: "JSON 文本不是有效 UTF-8")
        }
        return try decode(data)
    }

    func serialized(pretty: Bool = false) -> String {
        JSONValue.serialize(self, pretty: pretty)
    }

    static func serialize(_ value: JSONValue, pretty: Bool) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationObject, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 转回 Foundation 对象，供 JSONSerialization / URLSession 使用。
    var foundationObject: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationObject)
        case .object(let value): value.mapValues(\.foundationObject)
        }
    }
}
