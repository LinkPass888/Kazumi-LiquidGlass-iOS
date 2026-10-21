//
//  InfoTabPanels.swift
//  Kazumi
//
//  详情页「概览 / 吐槽 / 角色 / 关联 / 制作人员」五个标签的内容面板，
//  对应原版 lib/pages/info/info_tabview.dart 的五个面板：
//    * 概览     —— 简介；
//    * 吐槽     —— /p1/subjects/{id}/comments；
//    * 角色     —— /v0/subjects/{id}/characters；
//    * 关联     —— /v0/subjects/{id}/subjects；
//    * 制作人员 —— /v0/subjects/{id}/persons。
//

import SwiftUI

/// 详情页标签。与原版 info_page.dart 的 _infoTabs 逐条一致。
enum InfoTab: String, CaseIterable, Identifiable, Sendable {
    case overview
    case comments
    case characters
    case relations
    case staff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .comments: "吐槽"
        case .characters: "角色"
        case .relations: "关联"
        case .staff: "制作人员"
        }
    }
}

/// 面板里的空态 / 加载态。
struct InfoPanelPlaceholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

// MARK: - 概览

/// 概览面板：简介（对应原版 info_tabview.dart 的第一个面板）。
struct InfoOverviewPanel: View {
    let item: BangumiItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)

            Text(item.summary.isEmpty ? "暂无简介" : item.summary)
                .font(.callout)
                .foregroundStyle(item.summary.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 吐槽

/// 吐槽面板：对应原版 info_comments_view.dart。
struct InfoCommentsPanel: View {
    let comments: [BangumiCommentItem]
    let total: Int
    let isLoading: Bool

    var body: some View {
        if isLoading {
            InfoPanelPlaceholder(symbol: "ellipsis.bubble", text: "正在加载吐槽…")
        } else if comments.isEmpty {
            InfoPanelPlaceholder(symbol: "text.bubble", text: "还没有人吐槽这部番")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(comments) { comment in
                    row(comment)
                }
                if total > comments.count {
                    Text("已显示 \(comments.count) / \(total) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ comment: BangumiCommentItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            BangumiRemoteImage(url: comment.userAvatar)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.userName.isEmpty ? "匿名用户" : comment.userName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if comment.rate > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(String(format: "%.1f", Double(comment.rate) / 2))
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(KazumiPalette.accent)
                    }
                }
                Text(comment.comment)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 角色

/// 角色面板：对应原版 character_page.dart 的角色列表。
struct InfoCharactersPanel: View {
    let characters: [BangumiCharacterItem]
    let isLoading: Bool

    var body: some View {
        if isLoading {
            InfoPanelPlaceholder(symbol: "person.2", text: "正在加载角色…")
        } else if characters.isEmpty {
            InfoPanelPlaceholder(symbol: "person.2", text: "暂无角色信息")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(characters) { character in
                    HStack(alignment: .top, spacing: 12) {
                        BangumiRemoteImage(url: character.largeImage)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(character.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(character.relation)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(KazumiPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(KazumiPalette.accent.opacity(0.14)))
                            if !character.actorNames.isEmpty {
                                Text("CV：\(character.actorNames)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - 关联

/// 关联面板：前传 / 续集 / 角色等同系列条目。
struct InfoRelationsPanel: View {
    let relations: [BangumiRelationItem]
    let isLoading: Bool

    @Environment(AppRouter.self) private var router

    var body: some View {
        if isLoading {
            InfoPanelPlaceholder(symbol: "square.stack", text: "正在加载关联条目…")
        } else if relations.isEmpty {
            InfoPanelPlaceholder(symbol: "square.stack", text: "暂无关联条目")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(relations) { relation in
                    Button {
                        router.push(.bangumiInfo(bangumiID: relation.item.id))
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            BangumiRemoteImage(url: relation.item.largeImage)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(relation.item.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                if !relation.relation.isEmpty {
                                    Text(relation.relation)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(KazumiPalette.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(KazumiPalette.accent.opacity(0.14)))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 制作人员

/// 制作人员面板：原作 / 导演 / 声优等。
struct InfoStaffPanel: View {
    let staff: [BangumiStaffItem]
    let isLoading: Bool

    var body: some View {
        if isLoading {
            InfoPanelPlaceholder(symbol: "person.text.rectangle", text: "正在加载制作人员…")
        } else if staff.isEmpty {
            InfoPanelPlaceholder(symbol: "person.text.rectangle", text: "暂无制作人员信息")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(staff) { member in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(member.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if !member.relations.isEmpty {
                                Text(member.relations.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}