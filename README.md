# ezmv

Give free space from `D:` to `C:` on Windows when Disk Management says you can't, using only built-in Windows tools and keeping your files.

> **Status: beta (0.9.0).** Both tests in this repo pass on Windows 11: the file-handling test, and a full end-to-end run on a virtual disk that is interrupted at the worst moment and then resumed. Not yet exercised by a test: suspending and resuming BitLocker, moving Windows Recovery, and the roll-back path. It has not been proven on a wide range of real machines, so back up anything you cannot afford to lose and try `-PlanOnly` first.

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
- **The data drive must be less than about half full**, because its files have to fit on it twice for a moment
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

## What it detects and handles for you

| Situation | What ezmv does |
|---|---|
| BitLocker **on** for the target drive | Suspends protection during the work, resumes it at the end (even if the run fails) |
| BitLocker **off**, or not available on this edition | Nothing to do, continues normally |
| BitLocker already suspended | Leaves it as it is |
| BitLocker on for the data drive | Works, but warns that the recreated drive is not encrypted until you turn it on again |
| BitLocker still encrypting / decrypting | Stops and asks you to wait |
| Data drive locked by BitLocker | Stops and asks you to unlock it |
| Windows Recovery lives on the partition being removed | Disables it first (moves the image to the Windows drive), re-enables it at the end |
| No Recovery partition between the drives | Skips that step |
| Something other than a Recovery partition between the drives | Stops |
| Page file on the data drive | Stops and tells you how to move it |
| Programs running from the data drive | Lists them and waits until you close them |
| Laptop on battery | Warns and asks |
| Data drive needs a disk check | Stops and tells you to run `chkdsk` |
| Data drive too full, or cannot shrink far enough | Stops before changing anything |
| Unallocated space already on the disk | Stops (extend into it first) |
| Folder links (junctions) on the data drive | Lists them; they are not recreated |
| Script stored on the data drive | Stops and asks you to move it |

## If it gets interrupted

After every step ezmv saves its progress to a resume file. If the run stops for any reason (an error, a closed window, a reboot, a power cut), **just start ezmv again**. It shows where it stopped and offers to continue.

- **Stopped during steps 1-3:** nothing has been deleted yet. You can continue, or let ezmv roll back (remove the temporary drive and grow the data drive back).
- **Stopped during steps 4-8:** your files are on the temporary drive (`T:` unless that letter was taken). **Do not delete it.** Start ezmv again to finish.
- **Stopped during steps 9-10:** your files are back on the data drive; ezmv only needs to finish tidying up.

Logs are written to `%ProgramData%\ezmv\logs`.

## What you lose

- Restore points and shadow copies stored on the data drive
- The data drive's Recycle Bin contents
- Folder links (junctions) on the data drive
- BitLocker encryption on the data drive, until you turn it on again. During the run, files are written to drives that are not encrypted yet.
- The Recovery partition between the two drives (Windows Recovery itself is kept and re-enabled)

## Tests

```powershell
# no admin rights needed, never touches a partition
powershell -ExecutionPolicy Bypass -File .\tests\Test-Functions.ps1

# run as Administrator: full end-to-end run on a throw-away 8 GB virtual disk,
# including an interruption at the worst moment and a resume
powershell -ExecutionPolicy Bypass -File .\tests\Test-OnVirtualDisk.ps1
```

The virtual-disk test never selects your real disks: it creates a `.vhd` file in your temp folder, points ezmv at it with `-Target`, compares the SHA-256 of every file afterwards, then removes the virtual disk.

## Limitations

- GPT disks and NTFS data drives only
- The data drive must be the next lettered drive to the right of the target, on the same disk
- Needs the data drive to be under roughly half full
- Not for dynamic disks or Storage Spaces

## Disclaimer

This tool deletes and recreates partitions. It is provided as is, without warranty of any kind (see [LICENSE](LICENSE)). You are responsible for your backups.

## License

MIT
