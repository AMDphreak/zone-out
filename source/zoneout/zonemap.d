module zoneout.zonemap;

version (Windows):

import core.sys.windows.windef;
import core.sys.windows.winerror;
import core.sys.windows.winnt;
import core.sys.windows.winreg;
import std.algorithm : canFind, splitter;
import std.array : array, join, replace;
import std.conv : to;
import std.string : format;
import std.utf : toUTF16z;
import zoneout.domain : ZoneMapSplit;
import zoneout.exc : Exit, ZoneOutException;

pragma(lib, "advapi32");
pragma(lib, "shell32");

extern (Windows) BOOL IsUserAnAdmin();

enum ZoneHive
{
    hkcu,
    hklm,
}

enum trustedSitesZone = 2;
enum zoneMapRelative = `Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains`;
enum KEY_WOW64_64KEY_LOCAL = 0x0100;

struct ZoneEntry
{
    ZoneHive hive;
    string keyPath; /// relative to Domains, backslash-separated
    string host; /// reconstructed host
    string protocol;
    uint zoneId;
}

string hiveName(ZoneHive hive)
{
    final switch (hive)
    {
    case ZoneHive.hkcu:
        return "HKCU";
    case ZoneHive.hklm:
        return "HKLM";
    }
}

HKEY hiveRoot(ZoneHive hive)
{
    final switch (hive)
    {
    case ZoneHive.hkcu:
        return HKEY_CURRENT_USER;
    case ZoneHive.hklm:
        return HKEY_LOCAL_MACHINE;
    }
}

bool isElevated()
{
    return IsUserAnAdmin() != 0;
}

private string fromWidez(const(wchar)[] buf)
{
    size_t n;
    while (n < buf.length && buf[n] != 0)
        n++;
    return to!string(buf[0 .. n]);
}

private REGSAM writeSam()
{
    return KEY_READ | KEY_WRITE | KEY_WOW64_64KEY_LOCAL;
}

private REGSAM readSam()
{
    return KEY_READ | KEY_WOW64_64KEY_LOCAL;
}

private string relativeKey(ZoneMapSplit split)
{
    if (split.apex.length == 0)
        throw new ZoneOutException(
            "Cannot map '" ~ split.host ~ "' — not a registrable host (public suffix or empty).",
            Exit.error);
    if (split.leftover.canFind('\\') || split.leftover.canFind('/'))
        throw new ZoneOutException("Invalid leftover labels in '" ~ split.host ~ "'.", Exit.error);
    if (split.leftover.length)
        return split.apex ~ `\` ~ split.leftover;
    return split.apex;
}

string reconstructedHost(string keyPath)
{
    auto parts = keyPath.replace(`/`, `\`).splitter('\\').array;
    if (parts.length == 0)
        return null;
    if (parts.length == 1)
        return parts[0];
    auto leftover = parts[1 .. $].join(".");
    return leftover ~ "." ~ parts[0];
}

void requireHiveWritable(ZoneHive hive)
{
    if (hive == ZoneHive.hklm && !isElevated())
    {
        throw new ZoneOutException(
            "HKLM Zone Map requires an elevated process. Re-run from an Administrator terminal, or pass --hive hkcu.",
            Exit.notElevated);
    }
}

void writeZone(ZoneHive hive, ZoneMapSplit split, string protocol, uint zoneId, bool dryRun)
{
    requireHiveWritable(hive);
    auto rel = relativeKey(split);
    if (dryRun)
        return;
    auto path = zoneMapRelative ~ `\` ~ rel;
    HKEY hk;
    auto status = RegCreateKeyExW(
        hiveRoot(hive),
        path.toUTF16z,
        0,
        null,
        0,
        writeSam(),
        null,
        &hk,
        null);
    if (status != ERROR_SUCCESS)
    {
        throw new ZoneOutException(
            format("RegCreateKeyEx failed (%s) for %s\\%s", status, hiveName(hive), path),
            Exit.error);
    }
    scope (exit)
        RegCloseKey(hk);
    DWORD value = zoneId;
    status = RegSetValueExW(
        hk,
        protocol.toUTF16z,
        0,
        REG_DWORD,
        cast(BYTE*)&value,
        DWORD.sizeof);
    if (status != ERROR_SUCCESS)
    {
        throw new ZoneOutException(
            format("RegSetValueEx failed (%s) writing %s=%s", status, protocol, zoneId),
            Exit.error);
    }
}

void removeZone(ZoneHive hive, ZoneMapSplit split, string protocol, bool dryRun)
{
    requireHiveWritable(hive);
    auto rel = relativeKey(split);
    if (dryRun)
        return;
    auto path = zoneMapRelative ~ `\` ~ rel;
    HKEY hk;
    auto status = RegOpenKeyExW(hiveRoot(hive), path.toUTF16z, 0, writeSam(), &hk);
    if (status == ERROR_FILE_NOT_FOUND)
        return;
    if (status != ERROR_SUCCESS)
    {
        throw new ZoneOutException(
            format("RegOpenKeyEx failed (%s) for %s\\%s", status, hiveName(hive), path),
            Exit.error);
    }
    status = RegDeleteValueW(hk, protocol.toUTF16z);
    RegCloseKey(hk);
    if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND)
    {
        throw new ZoneOutException(
            format("RegDeleteValue failed (%s) for %s", status, protocol),
            Exit.error);
    }
}

ZoneEntry[] listZones(ZoneHive hive)
{
    ZoneEntry[] entries;
    HKEY hk;
    auto status = RegOpenKeyExW(hiveRoot(hive), zoneMapRelative.toUTF16z, 0, readSam(), &hk);
    if (status == ERROR_FILE_NOT_FOUND)
        return entries;
    if (status != ERROR_SUCCESS)
    {
        throw new ZoneOutException(
            format("RegOpenKeyEx failed (%s) opening %s ZoneMap\\Domains", status, hiveName(hive)),
            Exit.error);
    }
    scope (exit)
        RegCloseKey(hk);
    walk(hive, hk, "", entries);
    return entries;
}

private void walk(ZoneHive hive, HKEY hk, string rel, ref ZoneEntry[] entries)
{
    enum maxName = 256;
    DWORD index = 0;
    for (;;)
    {
        wchar[maxName] name;
        DWORD nameLen = maxName;
        DWORD type;
        BYTE[8] data;
        DWORD dataLen = data.length;
        auto status = RegEnumValueW(hk, index, name.ptr, &nameLen, null, &type, data.ptr, &dataLen);
        if (status == ERROR_NO_MORE_ITEMS)
            break;
        if (status == ERROR_SUCCESS)
        {
            if (type == REG_DWORD && dataLen >= 4)
            {
                ZoneEntry e;
                e.hive = hive;
                e.keyPath = rel;
                e.host = reconstructedHost(rel);
                e.protocol = fromWidez(name[0 .. nameLen]);
                e.zoneId = *cast(DWORD*) data.ptr;
                entries ~= e;
            }
            index++;
            continue;
        }
        break;
    }

    index = 0;
    for (;;)
    {
        wchar[maxName] name;
        DWORD nameLen = maxName;
        auto status = RegEnumKeyExW(hk, index, name.ptr, &nameLen, null, null, null, null);
        if (status == ERROR_NO_MORE_ITEMS)
            break;
        if (status != ERROR_SUCCESS)
            break;
        auto childName = fromWidez(name[0 .. nameLen]);
        auto childRel = rel.length ? rel ~ `\` ~ childName : childName;
        HKEY child;
        auto openStatus = RegOpenKeyExW(hk, childName.toUTF16z, 0, readSam(), &child);
        if (openStatus == ERROR_SUCCESS)
        {
            walk(hive, child, childRel, entries);
            RegCloseKey(child);
        }
        index++;
    }
}

struct PolicySnapshot
{
    bool hklmOnly;
    bool hklmOnlyReadable;
}

PolicySnapshot readHklmOnlyPolicy()
{
    PolicySnapshot snap;
    HKEY hk;
    auto path = `Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings`;
    auto status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, path.toUTF16z, 0, readSam(), &hk);
    if (status != ERROR_SUCCESS)
        return snap;
    scope (exit)
        RegCloseKey(hk);
    DWORD type;
    DWORD value;
    DWORD size = DWORD.sizeof;
    status = RegQueryValueExW(hk, "Security_HKLM_only".toUTF16z, null, &type, cast(BYTE*)&value, &size);
    if (status == ERROR_SUCCESS && type == REG_DWORD)
    {
        snap.hklmOnlyReadable = true;
        snap.hklmOnly = value != 0;
    }
    return snap;
}
