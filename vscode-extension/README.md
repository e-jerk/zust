# zust VS Code Extension

Provides real-time memory safety diagnostics for Zig via the zust analyzer LSP server.

## Features

- **Real-time diagnostics**: Detects use-after-free, double-free, pointer escapes, and raw pointer patterns as you type
- **Ownership annotations**: Highlights functions with `@safe(nocapture)`, `@safe(pure)`, and other ownership contracts
- **Zero configuration**: Works out of the box with the `zust-analyzer` binary on your PATH

## Requirements

- VS Code 1.74.0 or later
- The `zust-analyzer` binary must be available on your PATH (or configure `zust.serverPath`)

## Installation

1. Build the zust analyzer:
   ```bash
   cd zust
   zig build
   ```
   Ensure the resulting binary (`zig-out/bin/zust-analyzer` or `.zig-cache/...`) is on your PATH as `zust-analyzer`.

2. Install the extension:
   ```bash
   cd vscode-extension
   npm install
   npm run compile
   ```
   Then press `F5` in VS Code to launch the Extension Development Host.

## Configuration

| Setting | Description | Default |
|---------|-------------|---------|
| `zust.enable` | Enable/disable analysis | `true` |
| `zust.serverPath` | Path to analyzer binary | `zust-analyzer` |
| `zust.strictness` | Analysis strictness (`Low`, `Medium`, `High`) | `Medium` |

## Usage

Open any `.zig` file. Diagnostics will appear automatically in the Problems panel and inline in the editor.

## License

MIT
