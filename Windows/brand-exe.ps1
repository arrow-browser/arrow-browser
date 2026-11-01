# Gives Arrow.exe (CEF's bootstrap, renamed) Arrow's name, version and icon,
# which Windows shows in the taskbar, Task Manager, the print dialog and the
# "Select an app" picker, in place of "CEF Bootstrap Application".
#
#   powershell -File Windows\brand-exe.ps1 <Arrow.exe> [-Version 1.2.3]
#
# Replaces the executable's version resource (#1) and icon group (#32512,
# CEF's); its manifest and other resources stay.
param(
    [Parameter(Mandatory)] [string] $Executable,
    [string] $Version = '0.0.0',
    [string] $Icon = (Join-Path $PSScriptRoot 'Resources\Arrow.ico')
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class ArrowExecutable {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateResource(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool EndUpdateResource(IntPtr update, bool discard);

    const int RT_ICON = 3, RT_GROUP_ICON = 14, RT_VERSION = 16;
    const ushort EnglishUS = 1033;
    // CEF's bootstrap names its icon group IDI_APPLICATION.
    const int IconGroup = 32512;

    public static void Brand(string file, string version, string icon) {
        IntPtr update = BeginUpdateResource(file, false);
        if (update == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        bool done = false;
        try {
            Set(update, RT_VERSION, 1, VersionInfo(version));
            byte[] ico = File.ReadAllBytes(icon);
            int count = BitConverter.ToUInt16(ico, 4);
            var group = new MemoryStream();
            var writer = new BinaryWriter(group);
            writer.Write((ushort)0);
            writer.Write((ushort)1);
            writer.Write((ushort)count);
            for (int i = 0; i < count; i++) {
                int entry = 6 + i * 16;
                int size = BitConverter.ToInt32(ico, entry + 8);
                int offset = BitConverter.ToInt32(ico, entry + 12);
                byte[] image = new byte[size];
                Array.Copy(ico, offset, image, 0, size);
                Set(update, RT_ICON, i + 1, image);
                // GRPICONDIRENTRY: the ICONDIRENTRY's first 12 bytes, then the icon's ID.
                writer.Write(ico, entry, 12);
                writer.Write((ushort)(i + 1));
            }
            Set(update, RT_GROUP_ICON, IconGroup, group.ToArray());
            done = true;
        } finally {
            if (!EndUpdateResource(update, !done) && done) throw new System.ComponentModel.Win32Exception();
        }
    }

    static void Set(IntPtr update, int type, int name, byte[] data) {
        if (!UpdateResource(update, (IntPtr)type, (IntPtr)name, EnglishUS, data, (uint)data.Length))
            throw new System.ComponentModel.Win32Exception();
    }

    // VS_VERSIONINFO, with Arrow's strings in U.S. English, Unicode.
    static byte[] VersionInfo(string version) {
        ushort[] parts = new ushort[4];
        string[] given = version.Split('.');
        for (int i = 0; i < 4 && i < given.Length; i++) ushort.TryParse(given[i], out parts[i]);
        var fixedInfo = new MemoryStream();
        var f = new BinaryWriter(fixedInfo);
        f.Write(0xFEEF04BDu);                                  // dwSignature
        f.Write(0x00010000u);                                  // dwStrucVersion
        f.Write((uint)(parts[0] << 16 | parts[1]));            // dwFileVersionMS
        f.Write((uint)(parts[2] << 16 | parts[3]));            // dwFileVersionLS
        f.Write((uint)(parts[0] << 16 | parts[1]));            // dwProductVersionMS
        f.Write((uint)(parts[2] << 16 | parts[3]));            // dwProductVersionLS
        f.Write(0x3Fu);                                        // dwFileFlagsMask
        f.Write(0u);                                           // dwFileFlags
        f.Write(0x00040004u);                                  // dwFileOS: VOS_NT_WINDOWS32
        f.Write(1u);                                           // dwFileType: VFT_APP
        f.Write(0u);                                           // dwFileSubtype
        f.Write(0u);                                           // dwFileDateMS
        f.Write(0u);                                           // dwFileDateLS
        var strings = new List<byte[]>();
        foreach (var pair in new[] {
            new[] { "CompanyName", "Arrow" }, new[] { "FileDescription", "Arrow" },
            new[] { "FileVersion", version }, new[] { "InternalName", "Arrow" },
            new[] { "OriginalFilename", "Arrow.exe" }, new[] { "ProductName", "Arrow" },
            new[] { "ProductVersion", version } }) {
            byte[] text = Encoding.Unicode.GetBytes(pair[1] + "\0");
            strings.Add(Block(pair[0], text, (ushort)(text.Length / 2), 1));
        }
        byte[] table = Block("040904B0", new byte[0], 0, 1, strings.ToArray());
        byte[] stringInfo = Block("StringFileInfo", new byte[0], 0, 1, table);
        byte[] translation = Block("Translation", BitConverter.GetBytes(0x04B00409u), 4, 0);
        byte[] varInfo = Block("VarFileInfo", new byte[0], 0, 1, translation);
        return Block("VS_VERSION_INFO", fixedInfo.ToArray(), (ushort)fixedInfo.Length, 0, stringInfo, varInfo);
    }

    // A version block: its length, value length, type and key, then its
    // value and children, each on a 32-bit boundary.
    static byte[] Block(string key, byte[] value, ushort valueLength, ushort type, params byte[][] children) {
        var body = new MemoryStream();
        var w = new BinaryWriter(body);
        w.Write((ushort)0);
        w.Write(valueLength);
        w.Write(type);
        w.Write(Encoding.Unicode.GetBytes(key + "\0"));
        Pad(body);
        w.Write(value);
        foreach (byte[] child in children) {
            Pad(body);
            w.Write(child);
        }
        byte[] bytes = body.ToArray();
        BitConverter.GetBytes((ushort)bytes.Length).CopyTo(bytes, 0);
        return bytes;
    }

    static void Pad(MemoryStream stream) {
        while (stream.Length % 4 != 0) stream.WriteByte(0);
    }
}
'@

[ArrowExecutable]::Brand((Resolve-Path $Executable).Path, $Version, (Resolve-Path $Icon).Path)
Write-Host "Arrow.exe named Arrow $Version"
