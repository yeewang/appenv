# AppEnv

A native macOS app and CLI for selectable, persistent application environments.
Run Google Chrome, Visual Studio Code, and Codex concurrently with separate profile data.

## Build and open

Requires macOS 14 or later and Xcode command-line tools with Swift 5.10 or newer.

```sh
./scripts/build.sh
open dist/AppEnv.app
```

The build creates `dist/AppEnv.app` and `dist/bin/appenv`. Copy the app to your
Applications folder if desired. The default build is signed ad hoc for local use;
it is **not notarized or a distribution release**. Set `SIGN_IDENTITY` to a
Developer ID identity to sign a release candidate; notarization is a separate step.
Builds target the host architecture. The current artifact was tested on Apple silicon.

## Desktop use

1. Create an environment, such as Work or Personal.
2. Add Chrome, VS Code, or Codex using **Add App → Browse for Apps…**. The file picker
   supports multiple selections and **Shift-Command-G** to enter a path. You can
   also drag `.app` files from Finder into the app list or onto any environment
   in the sidebar. Targets highlight while you hover. Drag an existing app's icon
   onto another environment to add it there with a separate profile; this does
   not copy its profile data or move the installed application.
   The Add App menu also offers shortcuts for standard installations.
3. Click Open. Switch environments and open the same app again to get a separate instance.
4. Open again to focus the existing instance. Stop quits only the tracked instance.

The environment menu supports rename, stopped-profile duplication, ZIP export,
Reveal in Finder, and deletion to Trash. App menus offer an explicit force-stop
action and approval for using a profile with a changed application version.
The menu-bar item provides quick launch/focus and stop actions. Quitting AppEnv
leaves launched applications running; reopening AppEnv recovers their state.

## CLI

```sh
dist/bin/appenv create Work
dist/bin/appenv create Personal
dist/bin/appenv run --env Work --app chrome
dist/bin/appenv run --env Personal --app chrome
dist/bin/appenv run --env Work --app vscode
dist/bin/appenv run --env Work --app codex
dist/bin/appenv list --json
dist/bin/appenv stop Work
dist/bin/appenv duplicate Work 'Work Backup'
dist/bin/appenv export 'Work Backup' "$HOME/Desktop/Work-Backup.zip"
```

`run` adds an installed supported app automatically if necessary. For a custom location:

```sh
dist/bin/appenv add --env Work --app vscode --path '/path/Visual Studio Code.app'
```

For a shell-local default, use `export APPENV=Work`, then `appenv run --app chrome`.
This affects only AppEnv commands, not unrelated Finder or shell launches.
Use `appenv --help` for rename, delete, force-stop, and version-change options.

## Storage and runtime

- Default root: `~/Library/Application Support/AppEnv`.
- `APPENV_HOME` overrides the root for development or portable setups.
- `registry.json` stores versioned metadata and launch receipts, written atomically.
- Profiles live under `environments/<UUID>/apps/<bundle-id>/`.
- A nonblocking filesystem lock coordinates GUI and CLI operations. A busy client
  receives a retry message rather than queuing destructive operations.
- PID, launch timestamp, executable path, bundle identity, and exact profile arguments
  identify managed processes and recover missing launch receipts.
- App bundles remain unchanged; publisher code signatures are validated before launch.
- Readiness requires a live registered application, matching profile arguments, and
  app-specific profile files. It does not attest to account authentication or network health.
- VS Code and Codex use deterministic private symlinks in `/tmp/appenv-<uid>/` to keep
  Unix-domain socket paths below macOS's limit. Persistent files remain in the storage
  root. Aliases are recreated after reboot; dangling aliases contain no profile data.
- VS Code portable installations are rejected because portable mode overrides the
  configured profile directories.

The initial design's SQLite database and resident coordinator were simplified to
an atomic JSON registry plus cross-process locking for this small local MVP. UI and
CLI share the same Swift library. A resident service is not needed for persistence.

## Codex profiles

Choose **Add App → Codex**, browse to the installed app, or run `appenv run --env Work --app codex`.
AppEnv recognizes official `Codex.app` and newer `ChatGPT.app` installations with the
`com.openai.codex` bundle identity and OpenAI's publisher signature. The older native
ChatGPT app with a different bundle identity is not supported by this adapter.

Each environment has two separate persistent directories:

- `codex-home/`: local Codex configuration, sessions, backend state, and file-based credentials.
- `user-data/`: desktop UI settings, cookies, and Electron storage.

AppEnv sets both `CODEX_HOME` and `CODEX_ELECTRON_USER_DATA_PATH`, plus the matching
`--user-data-dir` argument. It does not copy your default Codex configuration, chats,
or credentials. Fresh environments start signed out; sign in within each environment.
Recovered process ownership must match both environment variables and the argument.
Stop also terminates matching app-bundled background helpers after the main process
quits. Other profiles and the original Codex app are excluded. Duplication and export
omit transient IPC sockets and pipes, which cannot be backed up as ordinary files.

Verified with installed Codex version **26.1013.40934** on Apple silicon, including two
concurrent managed profiles alongside an existing Codex session. These desktop launch
overrides were verified against that installed build; future versions may change them.
The existing version-change confirmation applies. Authentication status was verified
as signed out using the bundled CLI; an authenticated workflow and UI inspection were
not tested (Codex blocks computer-use access to its own UI). Cloud accounts, macOS
Keychain, permissions, external repositories, and some diagnostics/system services
remain outside the native-profile isolation boundary.

## Isolation boundary and current scope

Native profiles separate supported application data; they are **not a security sandbox**.
The macOS user, Keychain, TCC permissions, filesystem access, network, and some vendor
services remain shared. Signing into the same cloud account can synchronize data
across profiles. Documents opened by apps remain in their original locations.
AppEnv does not promise independent Keychain credentials or independent app versions.

Only the Chrome, VS Code, and Codex adapters are implemented. Other apps are rejected rather
than presented as isolated. There is no VM backend, arbitrary-app support, per-instance
network policy, import UI, automatic relaunch, or URL/file routing in this version.
Those are later stages of the design. ZIP exports are backups for manual recovery;
they may contain signed-in sessions and should be kept private. Stop apps before
copying/exporting profiles, and back up before permitting version changes. Force stop
can lose unsaved work. Exported sessions may depend on the original user's Keychain.

## Verification

```sh
swift test
python3 scripts/integration.py --cli dist/bin/appenv --run-apps
python3 scripts/integration.py --cli dist/bin/appenv --run-apps --apps codex
```

The integration test intentionally opens temporary Chrome and VS Code windows in a
logged-in macOS desktop session. It verifies four independent processes, focus reuse,
lost-receipt recovery, independent stop, restart persistence, protected running data,
duplication, and export. It stops its managed test instances and removes its profiles.
Both official apps must be installed in `/Applications` or `~/Applications`.
The optional Codex run checks separate desktop/backend state, credential non-inheritance,
two concurrent profiles, recovery, independent shutdown, restart, duplication, and export.

The socket-path regression is covered by unit tests. Tests also cover corrupted
registries, name collisions, independent copies, stale PIDs, publisher/app mismatch,
cross-client locking, invalid export destinations, target-specific app additions,
duplicate drops, and rejection of mixed valid/invalid selections without partial changes.
