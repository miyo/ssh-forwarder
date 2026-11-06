# SSH Forward Manager

A small Windows GUI for managing SSH local port forwarding. Define tunnels using ordinary `ssh` commands in a text file, then connect or disconnect each tunnel with a button.

The application uses Windows PowerShell and Windows OpenSSH. It does not implement SSH itself.

## Requirements

- Windows with **Windows PowerShell 5.1** and Windows Forms
- **Windows OpenSSH Client** (`ssh.exe`) available in `PATH`
- `Get-NetTCPConnection` available for checking local listening ports

## Setup

1. Put `SSHForwardButtons-fixed.ps1` and `ssh-forwards.txt` in the same directory.
2. Edit `ssh-forwards.txt` to define one SSH command per line. Blank lines and lines beginning with `#` are ignored.
3. Launch the GUI from PowerShell:

   ```powershell
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\SSHForwardButtons-fixed.ps1
   ```

   To launch from a Windows shortcut without showing the **main** PowerShell console, add `-WindowStyle Hidden`:

   ```text
   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\SSHForwardButtons-fixed.ps1"
   ```

   `-ExecutionPolicy Bypass` applies to the launched process; use it only if you trust the script. Organization-enforced execution policies may still prevent execution.

## Configuration

Use familiar SSH local-forwarding commands (`-L`). For example:

```text
ssh -f -N -L 13389:localhost:3389 example-rdp
ssh -f -N -L 20443:localhost:443 example-web
```

Host aliases such as `example-rdp` may be defined in `%USERPROFILE%\.ssh\config`. SSH handles authentication and jump hosts configured there (for example, `ProxyJump`). The GUI removes `-f`, adds `-N` if it is missing, and adds `-o ExitOnForwardFailure=yes` so it can manage the SSH process and detect forwarding setup failures.

This version is intended for **local forwarding (`-L`)**, not `-R` or `-D` forwarding. The port parser expects the `-L <local-port>:<destination-host>:<destination-port>` form (also accepting an optional localhost/loopback bind address).

## How it works

- **Connect:** Starts an SSH session in a separate console, where you can enter passwords or private-key passphrases. Multiple prompts are supported, including when connecting through jump hosts.
- **Connected:** When a process is listening on the configured local port, the GUI reports `Connected` and hides that SSH console.
- **Disconnect:** Terminates the managed session and its console.
- **Unexpected SSH exit:** Reports an error and shows the console again so you can review diagnostic output. Reconnecting cleans up the previous session first.
- **Exit:** Closing the GUI stops the sessions it started. Ctrl+C also triggers cleanup when launched from a visible PowerShell console.

Connection status is checked every two seconds. **`Connected` means that the local TCP port is in the LISTEN state**; it does not verify connectivity to the remote service, and the current check does not verify that the listener belongs to the specific SSH process.

## Security notes

- **No credential storage:** The GUI does not read, collect, save, or independently transmit SSH passwords or private-key passphrases. You enter them directly into the SSH console; Windows OpenSSH handles authentication. Normal SSH password authentication may transmit the password to the SSH server over the encrypted SSH connection. Private-key passphrases are used locally to unlock private keys.
- **Trust the configuration file:** `ssh-forwards.txt` contains commands that are used to build and run a Windows command script. The parser rejects some shell metacharacters but is **not a security sandbox**. Only use a configuration file that you have created or reviewed and that untrusted users cannot edit. SSH configuration can also invoke external programs (for example, via `ProxyCommand`).
- **Do not put secrets in configuration:** Do not put passwords or passphrases in `ssh-forwards.txt`, your shortcut, or command-line arguments.
- **Temporary files:** The application creates temporary batch files, console-window handle files, and SSH exit-status files. These do not intentionally contain authentication secrets.
- **Process termination:** Disconnect uses forced termination of the managed console process tree, including its SSH children.

## Limitations

- Windows only; designed for Windows PowerShell 5.1.
- Uses a separate console for interactive SSH authentication, hiding it once the local port begins listening.
- Requires trusted configuration and SSH host configuration.
- Assumes a distinct local listening port for each configured tunnel.

## License

Apache License 2.0. See [LICENSE](LICENSE).
