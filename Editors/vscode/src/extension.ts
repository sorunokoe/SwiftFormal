// SwiftFormal for VS Code: starts `swiftformal lsp` beside the Swift extension (it never replaces sourcekit-lsp) and
// shows the verdicts it publishes in the Test Explorer. All proving happens in the server; this file only wires it up.
import * as vscode from 'vscode';
import {
  ExecuteCommandRequest,
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from 'vscode-languageclient/node';

/** One verdict of `swiftformal/results`. */
interface ResultItem {
  /** Unique: names the package, as two packages may have targets of the same name. */
  id: string;
  /** The package directory. */
  package: string;
  module: string;
  function: string;
  uri: string;
  line: number;
  state: 'passed' | 'failed' | 'skipped' | 'stale';
  title: string;
  message: string;
  walk: boolean;
}

interface Results {
  generation: number;
  items: ResultItem[];
}

let client: LanguageClient | undefined;
/** `client.start()`: a restart waits for it to settle (a starting client cannot be stopped). */
let clientStart: Promise<void> | undefined;
let controller: vscode.TestController | undefined;

/** The settings the server reads (`initializationOptions` and `workspace/didChangeConfiguration`). */
function serverSettings(): Record<string, unknown> {
  const config = vscode.workspace.getConfiguration('swiftformal');
  return {
    checkOn: config.get<string>('checkOn', 'save'),
    scan: config.get<string[]>('scan', []),
    tests: config.get<string>('tests', ''),
    walks: config.get<boolean>('walks', true),
    budget: config.get<number | null>('budget', null),
  };
}

function startClient(context: vscode.ExtensionContext): LanguageClient {
  const command = vscode.workspace.getConfiguration('swiftformal').get<string>('path', 'swiftformal');
  // No transport option: the server speaks stdio, and the client then passes no `--stdio` flag.
  const serverOptions: ServerOptions = {
    run: { command, args: ['lsp'] },
    debug: { command, args: ['lsp'] },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'swift' }],
    initializationOptions: serverSettings(),
    synchronize: { configurationSection: 'swiftformal' },
    outputChannelName: 'SwiftFormal',
  };
  const languageClient = new LanguageClient('swiftformal', 'SwiftFormal', serverOptions, clientOptions);
  context.subscriptions.push(languageClient.onNotification('swiftformal/results', (results: Results) => showResults(results)));
  clientStart = languageClient.start().catch((error) => {
    console.warn(`SwiftFormal: the language server did not start: ${String(error)}`);
  });
  return languageClient;
}

/** Test Explorer items, module > file > function, rebuilt from each `swiftformal/results`. Publish-only: verdicts
 * come from the server's checks; there is no run button. A stale verdict is shown as skipped and says so. */
function showResults(results: Results): void {
  if (!controller) {
    return;
  }
  const tests = controller;
  const modules = new Map<string, vscode.TestItem>();
  const files = new Map<string, vscode.TestItem>();
  const run = tests.createTestRun(new vscode.TestRunRequest(), `swiftformal generation ${results.generation}`, false);
  for (const result of results.items) {
    const uri = vscode.Uri.parse(result.uri);
    const moduleKey = `${result.package}|${result.module}`;
    let module = modules.get(moduleKey);
    if (!module) {
      module = tests.createTestItem(`module:${moduleKey}`, result.module);
      module.description = vscode.workspace.asRelativePath(result.package);
      modules.set(moduleKey, module);
    }
    const fileKey = `${moduleKey}|${result.uri}`;
    let file = files.get(fileKey);
    if (!file) {
      file = tests.createTestItem(`file:${fileKey}`, vscode.workspace.asRelativePath(uri), uri);
      module.children.add(file);
      files.set(fileKey, file);
    }
    const item = tests.createTestItem(result.id, result.function, uri);
    item.range = new vscode.Range(result.line, 0, result.line, 0);
    item.description = result.title;
    item.tags = result.walk ? [new vscode.TestTag('walk')] : [new vscode.TestTag('logic')];
    file.children.add(item);
    report(run, item, result);
  }
  tests.items.replace([...modules.values()]);
  run.end();
}

function report(run: vscode.TestRun, item: vscode.TestItem, result: ResultItem): void {
  switch (result.state) {
    case 'passed':
      run.passed(item);
      break;
    case 'failed': {
      const message = new vscode.TestMessage(result.message || result.title);
      if (item.uri && item.range) {
        message.location = new vscode.Location(item.uri, item.range);
      }
      run.failed(item, message);
      break;
    }
    default:
      // `skipped` (not checked, or not a proof) and `stale` (the code changed since): never shown as passed.
      run.skipped(item);
  }
}

/** Stops and disposes `client`, whatever state it is in: `stop()` throws unless the client is running (a start that
 * failed, or one still starting), and a restart must go on after it. A start still going on gets a few seconds to
 * settle first, so its server is stopped too. */
async function stopClient(): Promise<void> {
  const old = client;
  const starting = clientStart;
  client = undefined;
  clientStart = undefined;
  if (!old) {
    return;
  }
  if (starting) {
    await Promise.race([starting, new Promise<void>((resolve) => setTimeout(resolve, 5000))]);
  }
  try {
    if (old.isRunning()) {
      await old.stop();
    }
  } catch (error) {
    console.warn(`SwiftFormal: stopping the language server failed: ${String(error)}`);
  }
  try {
    await old.dispose();
  } catch (error) {
    console.warn(`SwiftFormal: disposing the language server failed: ${String(error)}`);
  }
}

async function serverCommand(name: string): Promise<void> {
  if (!client) {
    return;
  }
  await client.sendRequest(ExecuteCommandRequest.type, { command: name, arguments: [] });
}

export function activate(context: vscode.ExtensionContext): void {
  controller = vscode.tests.createTestController('swiftformal', 'SwiftFormal');
  context.subscriptions.push(controller);
  client = startClient(context);
  context.subscriptions.push(
    vscode.commands.registerCommand('swiftformal.checkNow', () => serverCommand('swiftformal.server.check')),
    vscode.commands.registerCommand('swiftformal.cancel', () => serverCommand('swiftformal.server.cancel')),
    vscode.commands.registerCommand('swiftformal.restart', async () => {
      await stopClient();
      client = startClient(context);
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('swiftformal.path')) {
        void vscode.commands.executeCommand('swiftformal.restart');
      }
    }),
  );
}

export async function deactivate(): Promise<void> {
  await stopClient();
}
