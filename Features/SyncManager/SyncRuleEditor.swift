import StratusCore
import SwiftUI

public struct SyncRuleEditor: View {
    @Binding private var rules: [SyncRule]
    @State private var draftType: SyncRule.RuleType = .exclude
    @State private var draftScope: SyncRule.RuleScope = .name
    @State private var draftPattern = ""

    public init(rules: Binding<[SyncRule]>) {
        _rules = rules
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                Text("Sync Rules")
                    .font(.stratusHeadline)
                Spacer()
                Button("Reset Defaults") {
                    rules = SyncRule.defaultExcludes
                }
            }

            VStack(spacing: 0) {
                ForEach(rules) { rule in
                    SyncRuleRow(rule: rule) {
                        rules.removeAll { $0.id == rule.id && !$0.isBuiltIn }
                    }
                    if rule.id != rules.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
            .background(Color.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md, style: .continuous))

            HStack(spacing: Spacing.sm) {
                Picker("Type", selection: $draftType) {
                    Text("Include").tag(SyncRule.RuleType.include)
                    Text("Exclude").tag(SyncRule.RuleType.exclude)
                }
                .frame(width: 110)

                Picker("Scope", selection: $draftScope) {
                    Text("Name").tag(SyncRule.RuleScope.name)
                    Text("Path").tag(SyncRule.RuleScope.path)
                    Text("Extension").tag(SyncRule.RuleScope.extension)
                }
                .frame(width: 140)

                TextField("Pattern, e.g. *.tmp", text: $draftPattern)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    addRule()
                }
                .disabled(draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.lg)
    }

    private func addRule() {
        let pattern = draftPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        rules.append(SyncRule(type: draftType, pattern: pattern, scope: draftScope))
        draftPattern = ""
    }
}

private struct SyncRuleRow: View {
    let rule: SyncRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: rule.type == .exclude ? "minus.circle" : "plus.circle")
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(rule.pattern)
                .font(.stratusSmallMono)
            Spacer()
            Text(rule.scope.rawValue)
                .stratusCaption()
            if !rule.isBuiltIn {
                Button("Remove", action: remove)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }
}
