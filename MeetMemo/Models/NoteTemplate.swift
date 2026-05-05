import Foundation

struct TemplateSection: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var description: String
    
    init(id: UUID = UUID(), title: String, description: String) {
        self.id = id
        self.title = title
        self.description = description
    }
}

struct NoteTemplate: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var context: String
    var sections: [TemplateSection]
    var isDefault: Bool
    
    init(id: UUID = UUID(), title: String, context: String, sections: [TemplateSection] = [], isDefault: Bool = false) {
        self.id = id
        self.title = title
        self.context = context
        self.sections = sections
        self.isDefault = isDefault
    }
    
    // Generate the template content for the system prompt.
    // `sections` is retained only for older saved templates. New templates use
    // one free-form prompt in `context`.
    var formattedContent: String {
        legacySectionsMergedPrompt().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var promptPreview: String {
        legacySectionsMergedPrompt()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
    }

    func migratedToPromptOnly() -> NoteTemplate {
        guard !sections.isEmpty else { return self }
        return NoteTemplate(
            id: id,
            title: title,
            context: legacySectionsMergedPrompt(),
            sections: [],
            isDefault: isDefault
        )
    }

    private func legacySectionsMergedPrompt() -> String {
        var content = context.trimmingCharacters(in: .whitespacesAndNewlines)

        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = "模板类型：\(title)\n\n\(content)"
        }

        guard !sections.isEmpty else { return content }

        let sectionPrompt = sections
            .map { section in
                "- \(section.title)：\(section.description)"
            }
            .joined(separator: "\n")

        return """
        \(content)

        请按以下结构输出，可根据会议实际内容合并、删减或调整章节：
        \(sectionPrompt)
        """
    }
    
    // Default templates
    static func defaultTemplates() -> [NoteTemplate] {
        return [
            // 标准会议
            NoteTemplate(
                id: UUID(),
                title: "标准会议",
                context: """
                本次是一场正式的工作会议，可能包含议程讨论、方案评审或跨部门对齐等内容。请输出规范的会议纪要，适合存档和对外分发：

                ---

                # 会议纪要

                **会议主题**：
                **参会人员**：
                **主持人**：

                ## 会议目的
                本次会议召开的背景与目标。

                ## 议程与讨论内容

                ### 议题一：[议题名称]
                - 讨论摘要：
                - 结论：

                ### 议题二：[议题名称]
                - 讨论摘要：
                - 结论：

                （按实际议题数量增减）

                ## 决策事项
                | 决策内容 | 决策结果 | 决策人 |
                |----------|----------|--------|
                |          |          |        |

                ## 行动项
                | 行动项 | 负责人 | 截止时间 |
                |--------|--------|----------|
                |        |        |          |

                ## 待确认事项
                会议中提出但未在现场达成结论、需要后续确认的问题。

                ## 下次会议
                - 时间：
                - 议题预告：
                """,
                isDefault: true
            ),
            
            // 一对一沟通
            NoteTemplate(
                id: UUID(),
                title: "一对一沟通",
                context: """
                本次会议是一场一对一的双向沟通。请聚焦双方达成的共识、分歧点以及后续行动安排，从记录者的视角输出以下结构：

                ---

                # 一对一沟通记录

                **参与人**：
                **沟通主题**：[用一句话概括本次沟通的核心议题]

                ## 沟通背景
                本次沟通的起因或目的是什么？结合上下文材料与会议内容简要说明。

                ## 关键讨论点
                逐条列出双方重点沟通的内容：

                - **议题**：
                  - 一方观点：
                  - 另一方观点：
                  - 当前状态：已达成共识 / 存在分歧 / 待进一步确认

                ## 结论与共识
                列出双方明确达成一致的事项。

                ## 待跟进事项
                | 事项 | 负责人 | 截止时间 |
                |------|--------|----------|
                |      |        |          |

                ## 备忘
                会议中提及但暂不需要立即行动的信息，或记录者认为值得保留的背景内容。
                """,
                isDefault: true
            ),
            
            // 客户需求访谈
            NoteTemplate(
                id: UUID(),
                title: "客户需求访谈",
                context: """
                本次会议是对客户进行的需求调研或访谈。请重点还原客户的真实诉求、痛点与期望，并提炼对产品或业务决策有参考价值的洞察，输出以下结构：

                ---

                # 客户需求访谈报告

                **受访客户**：[姓名、职位、公司 / 背景，从转录中提取]
                **访谈目标**：[本次访谈希望了解的核心问题]

                ## 客户基本信息
                - 角色与业务场景：
                - 当前使用的解决方案 / 工具：
                - 决策权限：[是否为决策人或关键影响者]

                ## 核心痛点与需求
                | 痛点 / 需求 | 客户原话摘要 | 优先级（高 / 中 / 低） |
                |-------------|-------------|------------------------|
                |             |             |                        |

                ## 客户期望
                客户明确表达希望看到的解决方案、功能或结果。

                ## 隐性需求与洞察
                客户未明确说出，但从言语和态度中可以推断的深层诉求或顾虑。

                ## 关键引用语句
                直接摘录 2～4 句对理解需求最有价值的客户原话。

                ## 访谈结论
                基于本次访谈，对产品方向、优先级或业务策略有何参考意义？

                ## 后续行动
                | 事项 | 负责人 | 时间节点 |
                |------|--------|----------|
                |      |        |          |
                """,
                isDefault: true
            ),

            // 需求提报
            NoteTemplate(
                id: UUID(),
                title: "需求提报",
                context: """
                本次会议是业务方向产品团队提报具体需求的沟通会。请将会议讨论内容整理成标准需求文档草稿，供后续评审与排期使用。

                若上下文材料中包含相关背景信息，可在对应字段合理引用，并括注（参考上下文材料）。若某字段信息会议中未明确讨论，统一标注"会议中未明确"，不要填入推断内容。

                ---

                # 需求文档（Draft）

                **需求名称**：[从会议内容提取，或根据讨论主题命名]
                **需求来源**：[提报方姓名 / 部门]
                **文档状态**：草稿（待评审）

                ---

                ## 一、需求背景
                这个需求是在什么业务背景下被提出的？当前存在什么问题或机会？

                ## 二、目标与价值
                - **业务目标**：本需求希望达成的业务结果是什么？
                - **用户价值**：解决了哪类用户的什么问题？
                - **量化指标**：预期影响哪些可衡量的指标？（会议中未明确可标注）

                ## 三、需求范围

                **核心需求**
                会议中明确讨论且双方认可必须实现的功能或能力，逐条列出。

                **期望需求**
                会议中提及但非核心的需求，或基于背景判断应当纳入的内容。

                **暂不包含**
                会议中明确排除或暂不处理的内容。

                ## 四、用户与场景
                - **目标用户**：
                - **核心使用场景**：
                  - 场景一：[描述用户在什么情况下使用，做了什么，达成什么]
                  - 场景二：

                ## 五、产品方案概述
                基于会议讨论，描述初步的产品实现方向或方案思路。保留讨论中提及的关键决策点，不需要完整方案。

                ## 六、待确认问题
                | 问题描述 | 负责确认人 | 截止时间 |
                |----------|------------|----------|
                |          |            |          |

                ## 七、参考资料
                列出上下文材料中与本需求相关的内容来源及关键信息摘要。若无上下文材料则删除本节。
                """,
                isDefault: true
            ),
            
            // 招聘面试
            NoteTemplate(
                id: UUID(),
                title: "招聘面试",
                context: """
                本次是一场招聘面试，请对候选人的表现进行结构化评估，输出可用于内部讨论或存档的面试记录：

                ---

                # 面试评估报告

                **候选人**：[姓名，若转录中出现]
                **应聘岗位**：[从会议内容或上下文材料中提取]
                **面试官**：

                ## 候选人背景概要
                基于面试中候选人的自我介绍或问答，简要描述其工作经历、核心技能与背景。

                ## 结构化评估

                ### 专业能力
                - 评估表现：
                - 评级：优秀 / 良好 / 一般 / 不符合预期

                ### 思维与表达
                - 评估表现：
                - 评级：

                ### 动机与岗位匹配度
                - 候选人求职动机：
                - 与岗位 / 团队的匹配判断：
                - 评级：

                ### 其他维度（可选）
                如价值观、协作风格、抗压能力等，根据面试内容补充。

                ## 亮点
                候选人在面试中最令人印象深刻的 1～3 个表现。

                ## 顾虑与待确认项
                面试中出现的疑问、不确定信息或需要背调验证的内容。

                ## 综合建议
                - 整体评价：
                - 推进建议：推荐进入下一轮 / 保留观察 / 暂不推进
                - 补充说明：
                """,
                isDefault: true
            ),
            
            // 每日站会
            NoteTemplate(
                id: UUID(),
                title: "每日站会",
                context: """
                本次是团队每日站会，时间短、节奏快，核心目标是同步进展与暴露阻塞。请高度精炼输出，不展开分析：

                ---

                # 每日站会记录

                **参与人**：

                ## 各成员同步

                | 成员 | 昨日完成 | 今日计划 | 阻塞 / 风险 |
                |------|----------|----------|-------------|
                |      |          |          |             |

                ## 需协调的事项
                会议中提出的、需要跨成员协作或由负责人介入解决的阻塞问题。

                ## 今日重点提示
                基于本次站会，今天最需要关注的 1～2 件事。
                """,
                isDefault: true
            ),
            
            // 周团队会议
            NoteTemplate(
                id: UUID(),
                title: "周团队会议",
                context: """
                本次是团队定期周会，通常涵盖上周进展回顾、问题暴露与下周计划对齐。请重点关注整体进展健康度、风险项与决策事项，输出以下结构：

                ---

                # 周团队会议纪要

                **参与人**：
                **主持人**：[若能从转录中识别]

                ## 上周进展回顾
                按成员或工作模块整理：

                - **[成员 / 模块]**：
                  - 完成事项：
                  - 未完成事项及原因：

                ## 本周重点问题与决策
                | 问题描述 | 讨论结果 | 决策人 |
                |----------|----------|--------|
                |          |          |        |

                ## 风险与阻塞项
                当前存在的风险，或需要外部协调才能解决的问题。

                ## 下周计划
                - **[成员 / 模块]**：[下周重点任务]

                ## 重点关注
                本次会议结束后，最需要跟进或留意的 2～3 件事。
                """,
                isDefault: true
            ),
            
        ]
    }

    static let historicalDefaultTitles: Set<String> = [
        "咖啡聊天",
        "咖啡聊天 / 初识",
        "Coffee Chat / Intro",
        "Standard Meeting",
        "1 on 1",
        "Customer Discovery",
        "Hiring",
        "Standup",
        "Weekly Team Meeting"
    ]
} 
