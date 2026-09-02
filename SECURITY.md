# Security Policy

## Reporting a vulnerability

Please report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/scumbly/matcha/security/advisories/new)** — or from the repository's **Security** tab → **Report a vulnerability**.

That channel is private between you and the maintainer, so there's no need to publish anything before there's a fix.

Useful things to include: what an attacker gains, what access they need first, and the shortest path you found to reproduce it. A rough sketch is fine — a working exploit isn't required.

Matcha is a personal project maintained in spare time, so there's no guaranteed response window. Reports are read and taken seriously, and you'll be credited in the fix commit unless you'd rather not be.

## Supported versions

The latest release and the `main` branch. Fixes land on `main` and go out in the next release; nothing is backported to older tags. If you build from source, a fix reaches you with `git pull && ./build.sh --install`; if you run a downloaded build, replace it with the newer zip.

## What Matcha actually does

Worth stating plainly rather than implying more rigour than the project has: Matcha is one Swift file of roughly 470 lines. It opens no ports, speaks to no network, parses no untrusted input, and reads no files other than its own bundled icon. It stores two preferences — the chosen duration and whether the hotkey is enabled. The realistic attack surface is very small.

## Known and accepted risks

Documented trade-offs. Reporting one of these as a vulnerability isn't necessary — but a report showing one is **worse in practice than described**, or exploitable in a way this file doesn't anticipate, is genuinely useful and very welcome.

- **Builds are ad-hoc signed and not notarized.** There is no Developer ID behind them, so nothing cryptographically binds a release to its author, and macOS cannot tell an original from a substitute. If this repository's release assets were ever tampered with, a downloaded build would carry no signal. Building from source narrows that — you compile code you can read — though it isn't a complete answer either, since an attacker able to replace a release asset can often modify the source too. **Reports of tampering are very much in scope.**

- **The README documents how to strip the quarantine attribute.** `xattr -dr com.apple.quarantine` removes the flag that causes Gatekeeper to block the first launch. Being precise about what that check was doing: because the build is unnotarized, Gatekeeper was never verifying authorship — it only forced a deliberate "yes, I meant to run this." Removing the flag removes that speed bump and nothing more. It does not make an unverified binary verified, and it should only ever be pointed at a download you are already prepared to trust.

- **Suppressing display sleep also defers the lock that follows it.** This is the entire function of the app rather than a defect, but it deserves saying: while Matcha is active, a Mac set to lock once its display sleeps will not do so. Anyone with brief physical access to an unlocked Mac can turn it on — as they could with `caffeinate`, or by changing the setting in System Settings directly.

## What is in scope

- Anything that makes Matcha act outside its stated function
- Evidence that a published release does not correspond to the source at its tag
- The global hotkey observing input beyond the single combination it registers. Matcha uses Carbon `RegisterEventHotKey`, which registers one specific key with the window server and needs no Accessibility permission — it is not an input monitor, and evidence to the contrary would be a real finding
- Privilege escalation through the `SMAppService` login-item registration
- Anything reachable by a process that is **not** already running as your user account

## What is out of scope

- Anything requiring an attacker to already run code as your user account. Matcha runs with your privileges and holds no secrets; that account is assumed trusted.
- The accepted risks above, as described.
- Gatekeeper warnings on an unnotarized build — expected, and documented in the README.
