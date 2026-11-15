# ezmv

[![CI](https://github.com/devtint/ezmv/actions/workflows/ci.yml/badge.svg)](https://github.com/devtint/ezmv/actions/workflows/ci.yml)

Website: https://devtint.github.io/ezmv/

Give free space from `D:` to `C:` on Windows when Disk Management says you can't, using only built-in Windows tools and keeping your files.

> **Status: beta (0.11.2).** Both tests in this repo pass on Windows 11: the file-handling test, and a full end-to-end run on a virtual disk that is interrupted at the worst moment and then resumed. BitLocker and Windows Recovery handling, crash recovery and the roll-back path are tested with fakes for BitLocker and Windows Recovery; they have not yet been exercised against the real ones. It has not been proven on a wide range of real machines, so back up anything you cannot afford to lose and try `-PlanOnly` first.

## The problem

A very common laptop layout looks like this:

```
| EFI | C: (Windows) | Recovery | D: (Data) | Recovery |
```

You want to take 10 GB from `D:` and add it to `C:`. Disk Management refuses, for two reasons:

1. **Shrinking `D:` frees space at its end**, on the far side from `C:`.
2. **`C:` can only extend into free space that touches its right edge**, and a Recovery partition is sitting there.

Windows has no built-in way to slide a partition sideways, so the usual advice is "install a third-party partition manager".

## How ezmv solves it

It moves the *files* instead of the *partition*:

```
start      | C:        | Rec | D: (files)                         |
step 1-3   | C:        | Rec | D: (files)       | T: (copy)       |   shrink D:, create T:, copy + verify
step 4-5   | C:        |       free             | T: (files)      |   delete old D: and the Recovery partition
step 6     | C: +10 GB    |    free             | T: (files)      |   extend C:
step 7-8   | C: +10 GB    | D: (files)          | T: (files)      |   new D:, copy back + verify
step 9-10  | C: +10 GB    | D: (files)                            |   delete T:, grow D:
```

`D:` keeps its drive letter, label, files, timestamps and permissions.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 (already installed)
- A GPT disk (every UEFI PC)
- The data drive must be NTFS and sit right after the target drive, with nothing between them except Recovery partitions
- **The data drive must be less than about half full**, because its files have to fit on it twice for a moment. If it is fuller, use `-StagingPath` to keep the temporary copy on another NTFS drive (for example an external disk) instead
- Administrator rights (ezmv asks Windows for them itself)

## Usage

Download the script to the drive that will **grow** (not the data drive, which gets recreated):

```powershell
irm https://raw.githubusercontent.com/devtint/ezmv/main/ezmv.ps1 -OutFile "$env:USERPROFILE\ezmv.ps1"
```

**1. Dry run.** Detects everything and prints the plan. Changes nothing.

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\ezmv.ps1" -PlanOnly
```

**2. Real run.**

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\ezmv.ps1"
```

ezmv then:

1. shows the disk layout it detected and runs its safety checks
2. asks how many GB to move (and shows the allowed range)
3. prints the 10-step plan
4. waits for you to type `YES` before touching the disk
5. waits for you to type `DELETE` before removing the old data drive, which only happens after the copy has been verified
6. asks once more before removing the temporary drive

### Options

| Option | Meaning |
|---|---|
| `-PlanOnly` | Detect and print the plan, change nothing |
| `-Target E` | Grow drive `E:` instead of the Windows drive |
| `-GiveGB 10` | Amount to move, instead of being asked |
| `-VerifyHash` | Also compare the SHA-256 of every file after each copy (slower, strongest check) |
| `-Yes` | Answer every question with yes (unattended use and tests) |
| `-StatePath` | Where the resume file is kept (default `%ProgramData%\ezmv\state.json`) |
| `-StagingPath E:\ezmv-staging` | Keep the temporary copy in this folder on another NTFS drive instead of on a temporary partition. Lifts the half-full limit |
| `-FromFreeSpace` | The space after the target is already free (you deleted D: and Recovery yourself). Asks how much to add to the target, then builds target, a hidden 1 GB recovery partition, and a new data drive with the rest. No files are copied |
| `-DataLetter E` / `-DataLabel Data` | With `-FromFreeSpace`: letter and name of the new data drive (default D, Data) |
| `-FixRecovery` | Repair only: when Windows Recovery is off and `reagentc /enable` fails (for example with BitLocker on), puts the recovery image on the recovery partition after the Windows drive and enables it there |
| `-NoRecoveryPartition` | Do not create a new recovery partition; keep Windows Recovery on the Windows drive |

## What it detects and handles for you

| Situation | What ezmv does |
|---|---|
| BitLocker **on** for the target drive | Suspends protection during the work, resumes it at the end (even if the run fails; after a crash or power cut, the next run resumes it) |
| BitLocker **off**, or not available on this edition | Nothing to do, continues normally |
| BitLocker already suspended | Leaves it as it is |
| BitLocker on for the data drive | Works, but warns that the recreated drive is not encrypted until you turn it on again |
| BitLocker still encrypting / decrypting | Stops and asks you to wait |
| Data drive locked by BitLocker | Stops and asks you to unlock it |
| Windows Recovery lives on the partition being removed | Disables it first, creates a new hidden recovery partition (at least 1 GB, right after the target drive, as Microsoft recommends) and moves Windows Recovery onto it. After a crash, the next run finishes this |
| No Recovery partition between the drives | Skips that step |
| Something other than a Recovery partition between the drives | Stops |
| Page file on the data drive | Stops and tells you how to move it |
| Programs running from the data drive | Lists them and waits until you close them |
| Laptop on battery | Warns and asks |
| Data drive needs a disk check | Stops and tells you to run `chkdsk` |
| Data drive too full, or cannot shrink far enough | Stops before changing anything and suggests `-StagingPath` |
| Staging drive not NTFS, too small, or the folder not empty | Stops before changing anything |
| Staging drive unplugged after the old data drive was deleted | Stops and asks you to plug it back in |
| Unallocated space already on the disk | Stops and suggests `-FromFreeSpace` when the space is right after the target |
| Windows Recovery already healthy on another recovery partition (`-FromFreeSpace`) | Leaves it there and does not create a second one |
| Folder links (junctions) on the data drive | Lists them; they are not recreated |
| Script stored on the data drive | Stops and asks you to move it |

## If it gets interrupted

After every step ezmv saves its progress to a resume file. If the run stops for any reason (an error, a closed window, a reboot, a power cut), **just start ezmv again**. It shows where it stopped and offers to continue.

- **Stopped during steps 1-3:** nothing has been deleted yet. You can continue, or let ezmv roll back (remove the temporary drive and grow the data drive back).
- **Stopped during steps 4-8:** your files are on the temporary drive (`T:` unless that letter was taken). **Do not delete it.** Start ezmv again to finish.
- **Stopped during steps 9-10:** your files are back on the data drive; ezmv only needs to finish tidying up.

Logs are written to `%ProgramData%\ezmv\logs`.

The resume file decides which partitions an elevated ezmv deletes, so ezmv keeps `%ProgramData%\ezmv` readable and writable by Administrators and SYSTEM only, and refuses to act on a resume file (or a default folder) owned by anyone else.

The temporary drive is labelled `ezmv-temp`, so it is easy to tell apart from the data drive.

## What you lose

- Restore points and shadow copies stored on the data drive
- The data drive's Recycle Bin contents
- Folder links (junctions) on the data drive
- BitLocker encryption on the data drive, until you turn it on again. During the run, files are written to drives that are not encrypted yet.
- Nothing on the Recovery partition between the two drives except Windows Recovery, which moves to a new hidden recovery partition

## Drive will not shrink? (`shrink-unlock.ps1`)

Windows can only shrink a drive up to the last file it cannot move, so a drive with 45 GB free can still be limited to a few MB. On the Windows drive that file is usually the page file, the hibernation file, the memory dump or a restore point.

`shrink-unlock.ps1` is a small interactive menu that deals with this:

| Menu | What it does |
|---|---|
| 1 Check | How much the drive can shrink now, what is in the way, and the last unmovable file (from event 259) |
| 2 Unlock | Saves your current settings, turns off hibernation, the page file, the memory dump and System Restore for the drive, deletes its restore points, then restarts. The script opens again by itself after the restart |
| 3 Shrink | Runs `defrag /X` to consolidate free space, shows the new limit and shrinks by the GB you choose |
| 4 Restore | Turns every saved setting back on |

```powershell
irm https://raw.githubusercontent.com/devtint/ezmv/main/shrink-unlock.ps1 -OutFile "$env:USERPROFILE\shrink-unlock.ps1"
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\shrink-unlock.ps1"
```

Options: `-Drive C` to skip the drive question, `-Restore` to only turn the saved settings back on.

Deleted restore points cannot be brought back. If the last unmovable file is NTFS metadata (`$MFT`, `$LogFile`, `$Extend\...`), Windows cannot move it while running; use an offline partition tool booted from USB for more room.

## Tests

```powershell
# no admin rights needed, never touches a partition
powershell -ExecutionPolicy Bypass -File .\tests\Test-Functions.ps1

# run as Administrator: full end-to-end run on a throw-away 8 GB virtual disk,
# including an interruption at the worst moment and a resume
powershell -ExecutionPolicy Bypass -File .\tests\Test-OnVirtualDisk.ps1

# run as Administrator: kills ezmv mid-run like a power cut (with fake BitLocker
# and Windows Recovery), checks resume and roll-back clean up after it, and that
# a resume file planted by a normal user is refused
powershell -ExecutionPolicy Bypass -File .\tests\Test-Resilience.ps1
```

Both tests also run on every push and pull request on GitHub's Windows runners (see the CI badge above). Releases are built from tags like `v0.9.1` and come with a SHA-256 checksum file.

The virtual-disk test never selects your real disks: it creates a `.vhd` file in your temp folder, points ezmv at it with `-Target`, compares the SHA-256 of every file afterwards, then removes the virtual disk.

## Limitations

- GPT disks and NTFS data drives only
- The data drive must be the next lettered drive to the right of the target, on the same disk
- Needs the data drive to be under roughly half full, unless `-StagingPath` points to another drive with enough free space
- Not for dynamic disks or Storage Spaces

## Known limits

These are known and accepted for the beta:

- **A short window before D: is deleted.** A final sync and check run right before the old data drive is deleted, but a program could still write to it in the few seconds between that check and the deletion. Close everything that uses the drive.
- **Do not rearrange disks while a run is paused.** ezmv checks partition GUIDs and refuses to act on partitions it did not record, but it is not designed for partitions or drive letters being changed by hand between runs.
- **`-StatePath` is for tests and advanced use.** ezmv locks the folder it names to Administrators, but not the folders above it. The default location is fully protected.
- **Size check margin.** The new data drive must hold the measured copy plus 3% and 256 MB. Alternate data streams and file system overhead are covered by that margin, not measured exactly.
- **Windows Recovery and BitLocker are tested with fakes in CI.** Their real behaviour, including which partition `reagentc /enable` picks when there are two recovery partitions, still needs testing on real machines.

## Device Encryption (Windows 11 Home)

Device Encryption encrypts every new volume on its own, including the new data drive and the new recovery partition. Windows Recovery cannot be enabled on an encrypted partition, so ezmv decrypts the recovery partition (only that one) before enabling Recovery. The new data drive is left to Windows to encrypt. If Windows Recovery is ever found disabled again, run ezmv with `-FixRecovery`.

## Disclaimer

This tool deletes and recreates partitions. It is provided as is, without warranty of any kind (see [LICENSE](LICENSE)). You are responsible for your backups.

## License

MIT
