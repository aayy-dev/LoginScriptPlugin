# LoginScriptPlugin

**Run your own scripts as part of the Mac login itself, before macOS opens the user's home folder. Works with automatic login too.**

> **Status: still works on macOS 27 (October 2026).** The original project was last updated in 2018 and says it was "tested on 10.9". This fork rebuilt it natively for Apple silicon and tested it on macOS 27.0 on an M1 Mac mini, 13 major macOS releases later. The only code change is one small defensive patch. See [What was tested on macOS 27](#what-was-tested-on-macos-27).

LoginScriptPlugin was written in 2014 by Per Olofsson at the University of Gothenburg ([original repository][upstream]), based on Apple's [Technical Note TN2228, "Running At Login"][tn2228]. It hooks into the macOS login process, so your scripts run before any login items, LaunchAgents or apps start. That avoids race conditions that other login-time tricks can't avoid, and it works the same for typed and automatic logins.

This fork adds:

- a one-command build script, because the last release package only contains Intel code ([why that matters](#why-you-have-to-build-it-yourself)),
- a ready-made script for one common problem: **keeping your home folder on an external drive while still using automatic login**,
- this README, which explains that problem, how the plugin fixes it, and how to set it up even if you've never touched the macOS login system before.


## Contents

- [Is this your problem?](#is-this-your-problem)
- [What's actually going on](#whats-actually-going-on)
- [Why the usual fixes don't work](#why-the-usual-fixes-dont-work)
- [How LoginScriptPlugin fixes it](#how-loginscriptplugin-fixes-it)
- [Other things you can use it for](#other-things-you-can-use-it-for)
- [Setup guide](#setup-guide)
- [Checking that it works](#checking-that-it-works)
- [Undo and emergency recovery](#undo-and-emergency-recovery)
- [After macOS updates](#after-macos-updates)
- [Writing your own scripts](#writing-your-own-scripts)
- [What was tested on macOS 27](#what-was-tested-on-macos-27)
- [Related problems with an external home folder](#related-problems-with-an-external-home-folder)
- [Why you have to build it yourself](#why-you-have-to-build-it-yourself)
- [What this fork changes](#what-this-fork-changes)
- [Credits and license](#credits-and-license)


## Is this your problem?

You moved your home folder to an external drive. That's the folder with your name in `/Users`, which holds your documents, settings and app data. People often do this because a Mac with a small internal SSD, such as a 256 GB Mac mini, runs out of room. You also turned on **automatic login**, maybe because the Mac is a headless server you reach through Screen Sharing, SSH or a remote-desktop app. Since then, after restarting you see some of these:

- A **"Sign in to your Apple Account"** screen, as if the Mac were new. Signing in fails, even though you're already signed in.
- Apps such as password managers asking for your **"login" keychain password**, even though automatic login normally unlocks the keychain.
- iCloud saying some data isn't syncing, or settings that don't stick from one restart to the next.
- A partly filled `Library` folder on the internal disk "underneath" your home folder, which you can only see when the external drive is unmounted.
- It happens after some restarts but not others.

If that sounds familiar, the cause is almost certainly a race between automatic login and the external drive. This plugin fixes it without giving up automatic login or moving your home folder back to the internal disk.


## What's actually going on

**Mounting** is how macOS attaches a drive to a folder. The drive's contents appear inside a folder on the internal disk, called the *mount point*. In the examples here the mount point is `/Users/alice`. Before the drive is mounted, `/Users/alice` is just an empty folder on the internal disk. Once it's mounted, the drive covers that folder, and everything you see at that path is on the external drive.

When the Mac starts up, two things happen at the same time:

1. macOS finds the external drive and mounts it at `/Users/alice`. A USB or Thunderbolt drive takes a few seconds to show up.
2. **Automatic login** starts your session straight away, without stopping at the login window.

If the login wins, macOS looks in `/Users/alice`, finds an empty folder, and treats you as a brand-new user. It quietly creates a fresh `Library` folder there, with a new keychain, a new signed-out Apple Account database, and no record that setup was ever finished. A few seconds later the drive mounts over that folder and hides it. Programs that started early keep using the hidden copy on the internal disk, while everything that starts later uses your real home folder on the drive. You end up with two half-profiles at the same path, which explains every symptom above.

This is one boot where the login won, on the test Mac, taken from the system logs:

| Time | What happened |
|---|---|
| 16:35:21 | System services report "home directory is inaccessible" (only the empty mount point exists) |
| about 16:35:22 | Automatic login starts the user's session (estimated from when the user's preferences service started) |
| 16:35:25 | macOS starts mounting the external SSD |
| 16:35:29 | The mount finishes, about 7 seconds after the session started |

**To check whether this is happening to you:** every open file is on a particular device (drive), and you can compare those device numbers. While logged in, run this, replacing `alice` with your user name:

```bash
echo "home drive: $(stat -f '%Hd,%Ld' /Users/alice)   internal disk: $(stat -f '%Hd,%Ld' /System/Volumes/Data)"
sudo lsof -u alice 2>/dev/null | awk '$9 ~ "^/Users/alice" {print $6}' | sort | uniq -c
```

The second command counts the files your session has open in your home folder, grouped by device. If any are on the internal disk's number, some of your programs are using the hidden copy.


## Why the usual fixes don't work

| What people try | What happens |
|---|---|
| Mount external drives at startup with `AutomountDisksWithoutUserLogin` | Needed ([setup step 1](#step-1-make-the-drive-mount-by-itself-at-startup)), but not enough. The drive mounts earlier, but automatic login can still win by a few seconds. |
| Make the empty mount point unwritable (owned by root, mode `000`) | On macOS 27 the folder was reset to normal home-folder ownership and permissions during the login, most likely by the login process itself, and the new profile was created anyway. |
| A login hook (`defaults write com.apple.loginwindow LoginHook ...`) | It runs too late. Apple's TN2228: "The login hook is run at one specific time during the login process (after the home directory has been mounted)". Login hooks are also deprecated. |
| A LaunchAgent or login item that waits for the drive | Also too late: "Agents always run after the home directory has been mounted" ([TN2228][tn2228]). |
| Turn on automatic login only once the drive is mounted, then restart the login window | Restarting the login window doesn't trigger automatic login again. This was tested on macOS 27. |
| Turn off automatic login | Works, but after every restart or power cut the Mac sits at the login window until someone logs in. |
| Move the home folder back to the internal disk | Works, but defeats the purpose if the internal disk is too small. |


## How LoginScriptPlugin fixes it

Every login on a Mac, automatic or typed, goes through the same checklist of steps. The checklist is a rule named `system.login.console` in the macOS *authorization database*, and each step is called a *mechanism*. Here is the list on macOS 27 with the plugin added. The `<-` notes are explanations, not part of the list.

```
builtin:prelogin
builtin:policy-banner
loginwindow:login
builtin:login-begin
builtin:reset-password,privileged
loginwindow:FDESupport,privileged
builtin:forward-login,privileged
builtin:auto-login,privileged                 <- automatic login supplies the user name and password
builtin:authenticate,privileged
builtin:login-success
loginwindow:success
LoginScriptPlugin:premount-root,privileged    <- added: runs premount-root-* scripts as root
LoginScriptPlugin:premount-user,privileged    <- added: runs premount-user-* scripts
HomeDirMechanism:login,privileged             <- macOS opens (or creates) the home folder
HomeDirMechanism:status
MCXMechanism:login
CryptoTokenKit:login
LoginScriptPlugin:postmount-root,privileged   <- added: runs postmount-root-* scripts as root
LoginScriptPlugin:postmount-user,privileged   <- added: runs postmount-user-* scripts
loginwindow:done                              <- your desktop starts
```

Apple's TN2228 describes this approach. To run before the home folder is mounted, "you should install your mechanism before any instance of `HomeDirMechanism` in the array." LoginScriptPlugin is that kind of mechanism. It runs the scripts in `/Library/Application Support/LoginScriptPlugin`, waits for each one to finish, and refuses the login if a script exits with code 77.

The included script, [`examples/premount-root-wait-for-home.sh`](examples/premount-root-wait-for-home.sh), runs at the `premount-root` step:

1. It reads `/etc/fstab` to see whether the home folder that's logging in is on a drive that fstab mounts. If it isn't, for example an admin account on the internal disk, the login carries on immediately.
2. If it is, the script checks once a second until the drive is mounted, then lets the login carry on. Only then does macOS open the home folder, so it always finds the real one.
3. If the drive still hasn't appeared after 90 seconds (it's unplugged or broken), the script refuses the login rather than letting macOS build an empty profile. The Mac stays at the login window, and other accounts can still log in.

Here's a real boot on the test Mac with the plugin installed (user name changed):

```
17:23:05.900  running mechanism builtin:auto-login,privileged (8 of 20)
17:23:06.893  running mechanism LoginScriptPlugin:premount-root,privileged (12 of 20)
17:23:08      /Users/alice mounted (check 3)            <- the script waited about 2 seconds
17:23:08.984  running mechanism HomeDirMechanism:login,privileged (14 of 20)
17:23:40.742  Succeeded authorizing right 'system.login.console'
```

Without the plugin, this boot would have lost the race. With it, the whole session started on the external drive, with no Apple Account or keychain prompts.


## Other things you can use it for

The external home folder is just one example. What the plugin really provides is a way to run scripts as part of the login itself: before or after the home folder is opened, for typed and automatic logins alike, with the option to block the login. Some other uses are listed below. They are ideas; this fork has only tested the wait script.

- **Waiting for other storage.** Network home folders (SMB or NFS), or anything else that has to be ready before the session starts.
- **Preparing or repairing the home folder before it's used.** For example, create it from a template, or fix ownership after a migration.
- **Setting things up before any app starts.** A `postmount-root` script runs after the home folder is available but before login items, LaunchAgents and apps start, so they see its changes the first time they launch. This is useful on lab, classroom, kiosk and shared Macs, for example to reset an account to a known state at every login.
- **Blocking logins.** Exit with 77 to refuse a login, for example when a required drive or server is missing, or while a maintenance flag file exists.
- **Logging.** Record every login before the session starts.
- **Replacing a login hook.** Apple has deprecated login hooks, and there can only be one ([TN2228][tn2228]). This plugin runs any number of scripts, in name order.

The `*-user` modes run scripts as the user who's logging in, but the source notes that they still run in root's session. Use `*-root` scripts where you can.


## Setup guide

This guide covers the external home folder setup. For other uses, follow steps 2, 3, 5 and 6, and use your own scripts instead of step 4.

> [!WARNING]
> This changes how every login on the Mac works, and a broken setup can stop **everyone** from logging in at the login window. Before you start, make sure you have another way in. Turn on **Remote Login** (System Settings > General > Sharing), and check that you can SSH in from another computer as an admin account whose home folder is on the internal disk. Step 5 backs up the original login rules, so you can restore them with one command.

<details>
<summary><b>Short version for experienced admins</b></summary>

```bash
./build.sh "Apple Development: Your Name (TEAMID)"
sudo cp -R build/LoginScriptPlugin.bundle /Library/Security/SecurityAgentPlugins/
sudo chown -R root:wheel /Library/Security/SecurityAgentPlugins/LoginScriptPlugin.bundle
sudo install -d -o root -g wheel -m 755 "/Library/Application Support/LoginScriptPlugin"
sudo install -o root -g wheel -m 755 examples/premount-root-wait-for-home.sh "/Library/Application Support/LoginScriptPlugin/"
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true
security authorizationdb read system.login.console | sudo tee /var/root/system.login.console.orig.plist >/dev/null
sudo bash "Installer Resources/Scripts/configureplugin.sh" enable
sudo shutdown -r now    # authd only picks up the new rule after a restart
```

The home folder must be mounted by an `/etc/fstab` entry. The script waits for the longest fstab mount point that contains the home folder.

</details>

### What you need

- **A Mac with Apple silicon.** Testing was done on an M1 Mac mini running macOS 27.0. The build script targets macOS 11 or later and builds for Intel when you run it on an Intel Mac, but older macOS versions and Intel Macs haven't been tested.
- **Xcode, or just the Command Line Tools** (`xcode-select --install`).
- **A code-signing certificate.** An **Apple Development** certificate from a paid developer account worked. To create one, open Xcode > Settings > Accounts, add your Apple Account, then choose Manage Certificates > + > Apple Development. Xcode can also create one for a free Apple Account (a "Personal Team"), but that hasn't been tested with this plugin.
- **An admin account** and its password.
- **For the external home folder use case:**
  - The drive formatted as APFS, with ownership turned on. Check with `diskutil info /Users/alice | grep Owners`, which should say `Enabled`.
  - FileVault turned off. Automatic login isn't available while FileVault is on ([Apple][apple-autologin]).

### Step 1: Make the drive mount by itself at startup

*External home folder only.* The script uses `/etc/fstab` to work out which drive a home folder lives on, and the drive has to mount without waiting for anyone to log in.

**a. Mount the drive with `/etc/fstab`.** The tested setup mounts the drive's volume directly on the home folder's path. The top level of the drive *is* the home folder, so the account keeps its normal home path. The fstab line looks like this:

```
UUID=11111111-2222-3333-4444-555555555555 /Users/alice apfs rw,auto 0 0
```

Find your volume's UUID with `diskutil info "/Volumes/My SSD" | grep 'Volume UUID'`. Then edit fstab with `sudo vifs`. It opens the `vi` editor: press `G` then `o` to start a new line at the end, type or paste the line, then press `Esc` and type `:wq` to save.

If your home folder is somewhere else, such as `/Volumes/My SSD/Users/alice`, an fstab entry that mounts the volume at `/Volumes/My SSD` works too, because the script waits for whichever fstab mount point contains the home folder. In fstab, write a space in a path as `\040`, and write paths without symbolic links.

<details>
<summary><b>Haven't moved your home folder yet?</b> (outline, not tested step by step)</summary>

1. Back up everything first.
2. Format the external drive as APFS in Disk Utility, then turn ownership on: `sudo diskutil enableOwnership "/Volumes/My SSD"`.
3. Log out of `alice` and log in as a different admin account.
4. Copy the *contents* of `/Users/alice` to the top level of the drive, keeping owners and permissions: `sudo ditto /Users/alice "/Volumes/My SSD"`. Terminal may need Full Disk Access first (System Settings > Privacy & Security > Full Disk Access).
5. Move the old home folder aside and create an empty mount point: `sudo mv /Users/alice /Users/alice.old && sudo mkdir /Users/alice`.
6. Add the fstab line from step 1a, then mount the drive in its new place: `sudo diskutil unmount "/Volumes/My SSD" && sudo diskutil mount -mountPoint /Users/alice <Volume UUID>`.
7. Log in as `alice` and check that everything is there. Keep `/Users/alice.old` for a few weeks before deleting it.

</details>

**b. Let macOS mount external drives without waiting for a login:**

```bash
sudo defaults write /Library/Preferences/SystemConfiguration/autodiskmount AutomountDisksWithoutUserLogin -bool true
```

By default macOS only mounts external drives after someone logs in. The login is about to wait for the drive, so the drive mustn't wait for the login. Without this setting, the script would most likely time out and refuse the login. That's inferred from the boot logs, not tested.

**c. Optional: lock the empty mount point.** With the plugin installed, a login can no longer create a profile in the empty folder, so this is only an extra guard. **Only run this while the drive is unmounted.** While it's mounted, `/Users/alice` *is* the drive.

```bash
sudo chown root:wheel /Users/alice && sudo chmod 000 /Users/alice && sudo chflags uchg /Users/alice
```

The drive still mounts over a folder with the `uchg` (immutable) flag; this was tested. To rename or delete the folder later, first run `sudo chflags nouchg /Users/alice`.

To check this step, restart and wait at the login window. Then SSH in as your admin account and run `mount | grep ' on /Users/alice ('`. The drive should already be mounted.

### Step 2: Build the plugin

```bash
git clone https://github.com/aayy-dev/LoginScriptPlugin.git
cd LoginScriptPlugin
./build.sh                                          # lists your signing certificates
./build.sh "Apple Development: Your Name (AB12CD34EF)"
```

The last two lines of output should say `valid on disk` and `satisfies its Designated Requirement`. If you're connected over SSH and signing fails with `errSecInternalComponent`, your keychain is locked in that session. Run `security unlock-keychain ~/Library/Keychains/login.keychain-db` and try again.

### Step 3: Install the plugin

```bash
sudo mkdir -p /Library/Security/SecurityAgentPlugins
sudo rm -rf /Library/Security/SecurityAgentPlugins/LoginScriptPlugin.bundle
sudo cp -R build/LoginScriptPlugin.bundle /Library/Security/SecurityAgentPlugins/
sudo chown -R root:wheel /Library/Security/SecurityAgentPlugins/LoginScriptPlugin.bundle
codesign --verify --strict /Library/Security/SecurityAgentPlugins/LoginScriptPlugin.bundle && echo "plugin OK"
```

### Step 4: Install the wait script

```bash
D="/Library/Application Support/LoginScriptPlugin"
sudo mkdir -p "$D"
sudo cp examples/premount-root-wait-for-home.sh "$D/"
sudo chown -R root:wheel "$D"
sudo chmod 755 "$D" "$D/premount-root-wait-for-home.sh"
```

Run it once by hand. The drive is mounted right now, so it should print `exit=0` and log a `mounted (check 1)` line:

```bash
sudo "$D/premount-root-wait-for-home.sh" "$(id -u alice)" "$(id -g alice)" /Users/alice; echo "exit=$?"
tail -1 /var/log/wait-for-home.log
```

### Step 5: Back up the login rules, then turn the plugin on

```bash
security authorizationdb read system.login.console | sudo tee /var/root/system.login.console.orig.plist >/dev/null
sudo bash "Installer Resources/Scripts/configureplugin.sh" enable
security authorizationdb read system.login.console 2>/dev/null | grep -E 'auto-login|LoginScriptPlugin|HomeDirMechanism'
```

The first line saves the current rules in root's home folder on the internal disk, so the backup is there even when the external drive isn't. It prints `YES (0)` when it succeeds. The last command should show the two `premount` lines directly above `HomeDirMechanism:login,privileged`:

```
<string>builtin:auto-login,privileged</string>
<string>LoginScriptPlugin:premount-root,privileged</string>
<string>LoginScriptPlugin:premount-user,privileged</string>
<string>HomeDirMechanism:login,privileged</string>
<string>HomeDirMechanism:status</string>
<string>LoginScriptPlugin:postmount-root,privileged</string>
<string>LoginScriptPlugin:postmount-user,privileged</string>
```

### Step 6: Restart

```bash
sudo shutdown -r now
```

**Don't skip this.** In testing, a login right after enabling the plugin still used the old rules. The plugin only ran after a restart.


## Checking that it works

After the restart, give automatic login a minute, then SSH in as your admin account and run:

```bash
tail -5 /var/log/wait-for-home.log
log show --last boot --style compact --predicate 'process == "authd"' \
    | grep -E 'LoginScriptPlugin:premount-root|HomeDirMechanism:login,|Succeeded authorizing right .system.login.console'
who | grep console
```

What a pass looks like:

- **The wait log has a new line with this boot's time.** `check 1` means the drive was already mounted. A higher number means the plugin held the login until the drive was ready. Both are fine.
- **The authd lines appear in this order:** `LoginScriptPlugin:premount-root`, then `HomeDirMechanism:login`, then `Succeeded authorizing right 'system.login.console'`.
- **Your user is listed on `console`,** meaning automatic login worked.

Then run the device check from [What's actually going on](#whats-actually-going-on). Every open home-folder file should be on the home drive's device number, and none on the internal disk's.


## Undo and emergency recovery

**If a login is refused,** look at `/var/log/wait-for-home.log`. A `not mounted after 90s` line means the drive didn't mount. Fix the drive and restart. Accounts with home folders on the internal disk can still log in.

**To switch the plugin off from SSH,** use either of these, then restart:

```bash
sudo bash "Installer Resources/Scripts/configureplugin.sh" disable
# or restore the exact rules from before step 5:
sudo sh -c 'security authorizationdb write system.login.console < /var/root/system.login.console.orig.plist'
```

**The quickest switch-off** is to move the scripts out of the folder. With no scripts to run, the plugin does nothing and every login goes ahead. The plugin looks for scripts on every login, so this takes effect at the next login, without a restart.

```bash
sudo mkdir -p /var/root/LoginScriptPlugin-disabled
sudo mv "/Library/Application Support/LoginScriptPlugin/"* /var/root/LoginScriptPlugin-disabled/
```

**To uninstall completely,** run `configureplugin.sh disable` *first*, then delete the files, then restart. If the login rules still list a plugin that has been deleted, logins will probably fail (inferred, not tested).

```bash
sudo bash "Installer Resources/Scripts/configureplugin.sh" disable
sudo rm -rf /Library/Security/SecurityAgentPlugins/LoginScriptPlugin.bundle "/Library/Application Support/LoginScriptPlugin"
sudo shutdown -r now
```

**No SSH and no other account?** Start up in macOS Recovery, open Terminal, and move the scripts out of `Library/Application Support/LoginScriptPlugin` on the Data volume, for example `/Volumes/Macintosh HD - Data`. You may have to mount that volume in Disk Utility first. This path hasn't been tested.


## After macOS updates

"During some macOS upgrades and updates, the list of login mechanisms in the authorization database gets reset to its default state" ([Elliot Jordan][authdb-reset]). After every macOS update, check that the plugin is still enabled. This should print `4`:

```bash
security authorizationdb read system.login.console 2>/dev/null | grep -c LoginScriptPlugin
```

If it prints `0`, run `sudo bash "Installer Resources/Scripts/configureplugin.sh" enable` again and restart. Keep this repository, or at least `configureplugin.sh`, somewhere on the Mac. It's also worth checking that `defaults read /Library/Preferences/SystemConfiguration/autodiskmount` still shows `AutomountDisksWithoutUserLogin = 1`.


## Writing your own scripts

Put scripts in `/Library/Application Support/LoginScriptPlugin`. The plugin runs scripts whose names match these patterns, at these points in the login:

| Name starts with | Runs | As |
|---|---|---|
| `premount-root-` | before the home folder is opened | root |
| `premount-user-` | before the home folder is opened | the user logging in |
| `postmount-root-` | after the home folder is opened | root |
| `postmount-user-` | after the home folder is opened | the user logging in |

For example, a script named `postmount-user-com.example.redirect_library.sh` runs as the user logging in, after the home folder has been mounted. Each script gets these arguments:

| Variable | Value | Example |
|---|---|---|
| `$1` | UID | 501 |
| `$2` | GID | 20 |
| `$3` | Home folder | /Users/alice |

Rules and behaviour:

- **Permissions.** Every script, its folder and every folder above it must be owned by root, must not be a symbolic link, and must not be writable by anyone other than root and the `wheel` or `admin` groups. Scripts must be executable and must be on the startup disk. A script that breaks these rules is skipped silently, and the login goes ahead.
- **Exit codes.** Exit 0 to let the login carry on. Exit 77 (`EX_NOPERM`) to refuse it. Any other exit code also lets the login carry on.
- **Order.** Scripts in the same phase run one after another, in alphabetical order. The first one that exits with 77 stops the rest.
- **No time limit.** The plugin waits as long as a script runs, and the login waits with it. Always build your own timeout into anything that waits, as the example script does.
- **A minimal environment.** The session hasn't started yet, so `$HOME` and `$USER` aren't set and `$PATH` is very basic. Use full paths such as `/bin/sleep` and `/sbin/mount`.
- **Logging.** The plugin logs through Apple's old ASL system, which is deprecated. This fork didn't check whether those messages still show up in the unified log on macOS 27, so have your scripts write their own log file.


## What was tested on macOS 27

Test setup: M1 Mac mini, macOS 27.0 (build 26A428), Apple clang 21.0.0, an NVMe SSD in a USB-C enclosure (JMicron bridge, 10 Gb/s) holding the whole home folder, mounted with `/etc/fstab`, automatic login on.

**Verified**

- The 2014 code builds with current clang for arm64, with only deprecation warnings.
- `configureplugin.sh enable` works unchanged. It took the default 16-step login rule to 20 steps, with the `premount` steps right before `HomeDirMechanism`.
- Automatic login runs through the same rule: `builtin:auto-login` (step 8 of 20), then the plugin (step 12), then `HomeDirMechanism:login` (step 14).
- On cold boots, the wait script held the login for 1 to 2 seconds (`check 2` and `check 3`) until the SSD was mounted. The session then started entirely on the SSD, with no Apple Account or keychain prompts.
- macOS loaded the plugin signed with an **Apple Development** certificate, using the hardened runtime and a secure timestamp. No Developer ID certificate was needed.
- authd only used the changed login rule after a restart.
- `build.sh` (with `MIN_MACOS=13.0`) produces the same compiled code as the tested binary: identical `__text`, `__cstring` and `__const` sections and the same UUID.
- `/` and `/System/Volumes/Data` report the same device number, so the original "is the script on the boot volume?" check already passes on macOS 27. The patch in this fork is a safety net for systems where they differ ([details](#what-this-fork-changes)).
- Restarting the login window (`killall loginwindow`) doesn't trigger automatic login again.
- A root-owned, mode `000` mount point was reset to normal home-folder ownership during a login that beat the drive, and then filled. The login process most likely did this, but that wasn't confirmed.
- Mounting a drive over a folder with the `uchg` flag works.
- `sudo sysadminctl -autologin set ...` failed with `SACSetAutoLoginPassword error:22`. It set the user name but didn't create `/etc/kcpassword`. Setting automatic login in System Settings worked.
- Signing over SSH failed with `errSecInternalComponent` until the keychain was unlocked with `security unlock-keychain`.

**Observed but not explained.** The `MCXMechanism:login` step took about 31 seconds on the first login after each cold boot, compared with 0.4 seconds later on. It doesn't break anything, but it makes an unattended login slower.

**Inferred, not tested**

- `AutomountDisksWithoutUserLogin` is required, because otherwise the drive would wait for a login that is waiting for the drive.
- Deleting the plugin while it's still listed in the login rules would make logins fail.

**Not tested:** Intel Macs, macOS versions other than 27.0, ad-hoc signatures, free "Personal Team" certificates, the `*-user` script modes, the old Xcode project and installer package, and recovery from macOS Recovery.


## Related problems with an external home folder

These aren't fixed by the plugin, but people with an external home folder are likely to run into them.

**A screen-recording prompt after every restart.** Since macOS 15 Sequoia, apps that capture the screen without the system's picker, such as remote-desktop apps, show a recurring prompt: "... is requesting to bypass the system private window picker and directly access your screen and audio". With an external home folder it can come back after every restart, even after you click Allow. On the test Mac, the service that stores those approvals, `replayd`, couldn't save them. It logged `persistClientListToDisk ... NSCocoaErrorDomain Code=513`, and the sandbox log showed `deny(1) file-write-create /Users/alice/.TemporaryItems/...`. The likely reason is that macOS's safe-save writes a temporary copy on the same drive as the file, in the drive's `.TemporaryItems` folder, and replayd's sandbox doesn't allow that (inferred).

The workaround, tested with RustDesk, is to add the approval by hand with the current date. replayd reads it but can't overwrite it, so redo it within 30 days; that's the `2592000`-second interval. An entry dated far in the future was thrown away.

```bash
APP_ID=com.carriez.rustdesk   # the app's bundle ID: defaults read /Applications/RustDesk.app/Contents/Info.plist CFBundleIdentifier
P="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
PB=/usr/libexec/PlistBuddy
NOW="$(LC_ALL=C date -u '+%a %b %d %H:%M:%S GMT %Y')"
cp "$P" "$P.bak"
$PB -c "Delete :$APP_ID" "$P" 2>/dev/null
$PB -c "Add :$APP_ID dict" "$P"
$PB -c "Add :$APP_ID:kScreenCaptureAlertableUsageCount integer 1" "$P"
for k in kScreenCaptureApprovalLastAlerted kScreenCaptureApprovalLastUsed kScreenCapturePrivacyHintDate; do
    $PB -c "Add :$APP_ID:$k date '$NOW'" "$P"
done
$PB -c "Add :$APP_ID:kScreenCapturePrivacyHintPolicy integer 2592000" "$P"
killall replayd    # restarts by itself and rereads the file; do this while no screen capture is running
```

PlistBuddy's `Set` command rejects this date format, but `Add` accepts it, which is why the script deletes the entry and adds it again.

**A slow drive behind a dock or hub.** A home folder mostly does small random reads and writes, which suffer badly over the older USB storage protocol (BOT). Check which protocol the drive uses with `ioreg -l -w0 | grep -oE '"bInterfaceProtocol"=[0-9]+' | sort -u`. `98` is UASP, which is what you want, and `80` is BOT. On the test Mac, the same enclosure showed `80` through a Thunderbolt dock and `98` when plugged straight into the Mac. **Shut down before you move the drive.** Never unplug a mounted home folder.

**Keychain-unlock workarounds.** If you wrote a script to unlock your login keychain after logging in, you probably don't need it once logins can no longer land in the empty internal folder. Automatic login can then unlock the real keychain itself (inferred).


## Why you have to build it yourself

The last release, [1.0b32 from February 2016][releases], contains only an Intel (x86_64) binary, built against the OS X 10.11 SDK for OS X 10.7 and later. Apple silicon Macs can't load Intel code into a native process: "The system prevents you from mixing `arm64` code and `x86_64` code in the same process" ([Apple][apple-rosetta]). macOS 27 still includes an Intel helper for authorization plugins (`authorizationhosthelper.x86_64.xpc`), but it needs Rosetta, and that route wasn't tested. Rosetta also has an end date: Apple says it "will be available through macOS 27 — as a general-purpose tool", after which only "a subset of Rosetta functionality aimed at supporting older unmaintained gaming titles" will remain ([Apple][apple-rosetta]). A native build avoids all of this, and `build.sh` makes it one command.

The Xcode project from 2018 targets OS X 10.7 and signs with the University of Gothenburg's Developer ID. It hasn't been updated or tested in this fork; use `build.sh` instead.


## What this fork changes

Compared with the [original][upstream] (last commit April 2018):

- **`LoginScriptPlugin/LoginScriptPlugin.c`:** the check that a script is on the startup disk also accepts the Data volume (`/System/Volumes/Data`). Since macOS 10.15 the startup disk has been split into a read-only System volume at `/` and a Data volume that holds `/Library`. The original check compared each script's device number with `/` only. On macOS 27 both volumes report the same device number, so the original check passes there anyway, and this change is a harmless safety net for systems where they differ. Scripts on external drives are still rejected.
- **`build.sh`:** builds and signs the plugin with clang, without Xcode.
- **`examples/premount-root-wait-for-home.sh`:** waits for an fstab-mounted home folder.
- **This README**, which also keeps the original documentation in [Writing your own scripts](#writing-your-own-scripts).

`configureplugin.sh`, the Xcode project and the installer resources haven't changed.


## Credits and license

LoginScriptPlugin was created by Per Olofsson at the University of Gothenburg. The changes in this fork are released under the same license.

    Copyright 2014 Per Olofsson, University of Gothenburg. All rights reserved.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.


[upstream]: https://github.com/MagerValp/LoginScriptPlugin
[releases]: https://github.com/MagerValp/LoginScriptPlugin/releases
[tn2228]: https://developer.apple.com/library/archive/technotes/tn2228/_index.html
[apple-autologin]: https://support.apple.com/en-us/102316
[apple-rosetta]: https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment
[authdb-reset]: https://www.elliotjordan.com/posts/macos-authdb-mechs/
