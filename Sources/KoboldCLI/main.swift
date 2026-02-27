import ArgumentParser
import Foundation

@main
struct KoboldCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kobold",
        abstract: "KoboldOS — Native macOS AI Agent Runtime",
        version: "0.3.4",
        subcommands: [
            InteractiveChatCommand.self,
            DaemonCommand.self,
            ModelCommand.self,
            MetricsCommand.self,
            TraceCommand.self,
            SafeModeCommand.self,
            DiagnoseCommand.self,
            ChatCommand.self,
            HealthCommand.self,
            MemoryCommand.self,
            TaskCommand.self,
            WorkflowCommand.self,
            HistoryCommand.self,
            SkillCommand.self,
            SecretCommand.self,
            ConfigCommand.self,
            CheckpointCommand.self,
            CardCommand.self
        ],
        defaultSubcommand: InteractiveChatCommand.self
    )
}
