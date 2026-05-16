import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("zust");
  const enabled = config.get<boolean>("enable", true);
  if (!enabled) {
    return;
  }

  const serverPath = config.get<string>("serverPath", "zust-analyzer");
  const strictness = config.get<string>("strictness", "Medium");

  // Server options: spawn the analyzer with --lsp
  const serverOptions: ServerOptions = {
    command: serverPath,
    args: ["--lsp", "--strictness", strictness],
    transport: TransportKind.stdio,
  };

  // Client options
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "zig" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.zig"),
    },
  };

  client = new LanguageClient(
    "zust",
    "zust Memory Safety Analyzer",
    serverOptions,
    clientOptions
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}
