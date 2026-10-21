# AppEnv

A native macOS app and CLI for selectable, persistent application environments.
Run Google Chrome and Visual Studio Code concurrently with separate profile data.

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
2. Add Chrome or VS Code. The app locates standard installations; you can select
   another location through the application's menu.
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
- VS Code uses a deterministic private symlink in `/tmp/appenv-<uid>/` to keep its
  Unix-domain socket path below macOS's limit. Persistent files remain in the storage
  root. Aliases are recreated after reboot; dangling aliases contain no profile data.
- VS Code portable installations are rejected because portable mode overrides the
  configured profile directories.

The initial design's SQLite database and resident coordinator were simplified to
an atomic JSON registry plus cross-process locking for this small local MVP. UI and
CLI share the same Swift library. A resident service is not needed for persistence.

## Isolation boundary and current scope

Native profiles separate supported application data; they are **not a security sandbox**.
The macOS user, Keychain, TCC permissions, filesystem access, network, and some vendor
services remain shared. Signing into the same cloud account can synchronize data
across profiles. Documents opened by apps remain in their original locations.
AppEnv does not promise independent Keychain credentials or independent app versions.

Only the Chrome and VS Code adapters are implemented. Other apps are rejected rather
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
```

The integration test intentionally opens temporary Chrome and VS Code windows in a
logged-in macOS desktop session. It verifies four independent processes, focus reuse,
lost-receipt recovery, independent stop, restart persistence, protected running data,
duplication, and export. It stops its managed test instances and removes its profiles.
Both official apps must be installed in `/Applications` or `~/Applications`.

The socket-path regression is covered by unit tests. Tests also cover corrupted
registries, name collisions, independent copies, stale PIDs, publisher/app mismatch,
cross-client locking, and invalid export destinations.
