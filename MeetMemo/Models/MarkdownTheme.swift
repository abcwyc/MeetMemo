import Foundation

enum MarkdownTheme: String, CaseIterable, Codable, Identifiable {
    case meetMemo = "meetmemo"
    case github = "github"
    case bear = "bear"
    case typora = "typora"
    case sspai = "sspai"

    var id: String { rawValue }

    var chineseLabel: String {
        switch self {
        case .meetMemo: return "MeetMemo（推荐）"
        case .github: return "GitHub"
        case .bear: return "Bear"
        case .typora: return "Typora"
        case .sspai: return "少数派"
        }
    }

    var englishLabel: String {
        switch self {
        case .meetMemo: return "MeetMemo (Recommended)"
        case .github: return "GitHub"
        case .bear: return "Bear"
        case .typora: return "Typora"
        case .sspai: return "SSPAI"
        }
    }

    var chineseDescription: String {
        switch self {
        case .meetMemo: return "贴合应用界面的紧凑布局、柔和底色与蓝色强调。"
        case .github: return "标准 GitHub Markdown 排版与表格样式。"
        case .bear: return "参考 Bear 默认排版：圆润标题、1.5 倍行高与红色交互强调。"
        case .typora: return "基于 Typora Whitey：衬线正文、居中标题与编辑出版感。"
        case .sspai: return "参考附件的红色标题边栏、宽松行距与内容感样式。"
        }
    }

    var englishDescription: String {
        switch self {
        case .meetMemo: return "Compact spacing, soft surfaces, and blue accents matched to the app."
        case .github: return "Standard GitHub Markdown typography and tables."
        case .bear: return "Bear-inspired rounded headings, 1.5 leading, and red interaction accents."
        case .typora: return "Based on Typora Whitey with serif body text and centered editorial headings."
        case .sspai: return "Red heading rails, generous leading, and editorial styling inspired by Sspai."
        }
    }
}
