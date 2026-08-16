# Security Policy

## Supported versions

Security fixes are made against the latest release. Please make sure you are on the
most recent version before reporting an issue.

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities.

Use GitHub's private vulnerability reporting instead: go to the **Security** tab of
this repository and click **"Report a vulnerability"**. That opens a private
advisory visible only to the maintainers.

Please include:

- A description of the issue and its impact.
- Steps to reproduce, or a proof of concept.
- The app version and your macOS version.

This is a small project, so please calibrate accordingly: expect an
acknowledgement within about a week, and note that there is no bug bounty. Once a
fix is available, a new release is published and the advisory is disclosed
responsibly, with credit if you would like it.

## What is in scope

Nockerl Voice is a local macOS application with unusually broad reach. It is not
sandboxed, it watches the keyboard, and it types into other applications. Being
direct about that matters, because it is the most likely place for a real
vulnerability to live:

- **The app is deliberately not sandboxed.** A system-wide keyboard tap and
  pasting into other applications are both impossible from inside the App Sandbox,
  so the app ships without it.
- **A global keyboard event tap** (Input Monitoring) watches for the Right Command
  hotkey and the few keys that drive the recording popup. It is intended to be
  listen-only, to swallow no keystrokes, and to neither record nor transmit what
  you type. A way to make it capture or leak more than that is a vulnerability.
- **Text insertion into the frontmost application** (Accessibility) synthesizes a
  paste and saves and restores the clipboard around it. Transcribed text reaching
  the wrong destination, or clipboard contents leaking or failing to restore, is a
  vulnerability.

Also of particular interest:

- Handling of API keys (stored in the macOS Keychain).
- Handling of recorded audio and transcribed text (stored on-device).
- The transcription request path to a configured endpoint or to OpenRouter.
- The build and release pipeline and its supply-chain integrity.

## What is out of scope

- The app requesting Microphone, Input Monitoring, and Accessibility at all. All
  three are required for it to function and are documented in the README.
- Attacks that need physical access to an already unlocked Mac, or that need
  administrator rights you would have to grant first.
- Vulnerabilities in third-party services such as OpenRouter, or in a custom
  transcription endpoint you configured yourself. Report those to their owners.

## Verifying a release

Every release is built in public and is verifiable end to end. You can confirm a
downloaded build was produced from this exact source using its SLSA build
provenance attestation, its published SHA-256 checksum, and Apple notarization.
See the **Install** section of the [README](README.md) for the exact commands.
