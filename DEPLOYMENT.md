# Presentation Mode deployment bundle

## Contents

- `companion-module-presentation-mode/` — GitHub-ready Bitfocus Companion connection module source.
- `companion-module-presentation-mode.zip` — install/transfer archive of that module.
- `Presentation Mode.app.zip` — compiled macOS application, including the NDI runtime and notices.
- `SHA256SUMS.txt` — transfer-integrity checksums.

## Publish the Companion module to GitHub

On the other computer, extract this deployment ZIP and open Terminal in the extracted folder:

```bash
cd companion-module-presentation-mode
git init -b main
git add .
git commit -m "Initial Presentation Mode Companion module"
gh repo create presentation-mode --public --source=. --remote=origin --push
```

If GitHub CLI is not installed:

```bash
brew install gh
gh auth login
```

GitHub repository URLs cannot contain spaces, so `Presentation Mode` is represented by the repository slug `presentation-mode`; the module's displayed name remains `Presentation Mode`.

## Install the macOS app

The easiest transfer artifact is `Presentation-Mode-Installer.dmg`. Open it,
drag **Presentation Mode** onto the **Applications** shortcut, then follow the
included `READ ME.txt`.

To regenerate the installer from an existing bundle:

```bash
work/PresentationMode-DeckLink/Packaging/create-installer.sh \
  "outputs/Presentation Mode.app" \
  "outputs/Presentation-Mode-Installer.dmg"
```

1. Open `Presentation-Mode-Installer.dmg`.
2. Drag `Presentation Mode.app` to the `Applications` shortcut.
3. Control-click the installed app, choose **Open**, then confirm **Open**.
4. Approve Screen Recording and Local Network access if macOS requests them.
5. Add the app under **System Settings → General → Login Items** if it should launch automatically.
6. Select the active DeckLink endpoints exposed by that Mac's existing card profile.
7. Enable NDI only on computers that need it. Enter the exact sender name used by ProPresenter; the default is `<Mac name> - NDI 1`.
8. When ProPresenter opens, the app automatically releases production outputs. When ProPresenter quits, it returns to Canva Mode.

The application is ad-hoc signed. Moving or rebuilding it can cause macOS to request privacy permissions again.

## Configure Companion

Presentation Mode listens on TCP port `9876`. In the Companion connection, enter the Presentation Mode Mac's IP address and port `9876`. If Companion runs on the same Mac, use `127.0.0.1`.

The module provides Canva, Production, and Automatic Reconcile actions plus mode, ProPresenter, and NDI feedback/status variables.
