param(
    [ValidateRange(1024, 4096)]
    [int]$VhdSizeMiB = 1024,
    [ValidateRange(4096, 67108864)]
    [int]$CloneBytes = 4194304
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Host "FAIL: $($_.Exception.Message)"
    exit 1
}

if (-not $IsWindows) {
    throw 'This probe requires Windows.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This probe requires an elevated administrator token.'
}

foreach ($command in 'New-VHD', 'Mount-DiskImage', 'Dismount-DiskImage', 'Initialize-Disk', 'New-Partition', 'Format-Volume') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $command"
    }
}

if ($CloneBytes % 4096 -ne 0) {
    throw 'CloneBytes must be 4096-byte aligned.'
}

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

public static class RefsBlockClone
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DuplicateExtentsData
    {
        public IntPtr FileHandle;
        public long SourceFileOffset;
        public long TargetFileOffset;
        public long ByteCount;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        Microsoft.Win32.SafeHandles.SafeFileHandle device,
        uint controlCode,
        ref DuplicateExtentsData input,
        uint inputSize,
        IntPtr output,
        uint outputSize,
        out uint bytesReturned,
        IntPtr overlapped);

    // FSCTL_DUPLICATE_EXTENTS_TO_FILE
    private const uint DuplicateExtentsToFile = 0x00098344;

    public static void Clone(string sourcePath, string destinationPath, long byteCount)
    {
        using (var source = new FileStream(sourcePath, FileMode.Open, FileAccess.Read,
                   FileShare.ReadWrite | FileShare.Delete))
        using (var destination = new FileStream(destinationPath, FileMode.OpenOrCreate,
                   FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
        {
            destination.SetLength(byteCount);
            var input = new DuplicateExtentsData {
                FileHandle = source.SafeFileHandle.DangerousGetHandle(),
                SourceFileOffset = 0,
                TargetFileOffset = 0,
                ByteCount = byteCount,
            };
            uint ignored;
            if (!DeviceIoControl(destination.SafeFileHandle, DuplicateExtentsToFile, ref input,
                    (uint)Marshal.SizeOf(typeof(DuplicateExtentsData)), IntPtr.Zero, 0,
                    out ignored, IntPtr.Zero))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
    }
}
'@

$root = Join-Path ([IO.Path]::GetTempPath()) "refs-block-clone-poc-$([Guid]::NewGuid())"
$vhdPath = Join-Path $root 'volume.vhdx'
$mounted = $false

try {
    New-Item -ItemType Directory -Path $root | Out-Null
    New-VHD -Path $vhdPath -SizeBytes ($VhdSizeMiB * 1MB) -Dynamic | Out-Null
    Mount-DiskImage -ImagePath $vhdPath | Out-Null
    $mounted = $true

    $disk = Get-DiskImage -ImagePath $vhdPath | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem ReFS -NewFileSystemLabel RefsClone -Force -Confirm:$false | Out-Null

    $volume = Get-Volume -DriveLetter $partition.DriveLetter
    if ($volume.FileSystem -ne 'ReFS') {
        throw "Expected ReFS, got $($volume.FileSystem)."
    }

    $source = "$($partition.DriveLetter):\source.bin"
    $destination = "$($partition.DriveLetter):\destination.bin"
    $payload = [byte[]]::new($CloneBytes)
    $payload[0] = 0x41
    $payload[$payload.Length - 1] = 0x5A
    [IO.File]::WriteAllBytes($source, $payload)

    [RefsBlockClone]::Clone($source, $destination, $CloneBytes)
    if ((Get-FileHash $source -Algorithm SHA256).Hash -ne (Get-FileHash $destination -Algorithm SHA256).Hash) {
        throw 'The clone contents differ from the source.'
    }

    $stream = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.WriteByte(0x42)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    if ([IO.File]::ReadAllBytes($source)[0] -ne 0x41) {
        throw 'Writing the clone changed the source.'
    }

    Write-Host "PASS: ReFS block clone and copy-on-write verified on $($partition.DriveLetter):"
}
finally {
    if ($mounted) {
        Dismount-DiskImage -ImagePath $vhdPath | Out-Null
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}
