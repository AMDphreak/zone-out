module zoneout.cli;

import std.conv : to;
import std.json : JSONValue;
import std.stdio : stderr, stdout;
import std.string : startsWith, toLower;
import zoneout.buildinfo;
import zoneout.domain;
import zoneout.exc;
import zoneout.lists;

version (Windows)
{
    import zoneout.zonemap;
}

enum helpText = `zone-out — put known-good download origins in Windows Trusted Sites.

USAGE
  zone-out <command> [domain] [options]

COMMANDS
  apply       Write the bundled seed list into the Zone Map (skips denylist hits)
  add HOST    Trust one host (https → ZoneId=2). Rejected if denylisted
  remove HOST Remove the protocol value for that host
  list        Show Zone Map entries in HKCU and/or HKLM
  seed        Print the bundled allowlist
  denylist    Print origins that will never be trusted
  doctor      Redacted support dump (version, hive, elevation, policy)
  help        This text
  version     Print version and build id

OPTIONS
  --hive hklm|hkcu   Force a hive (default: HKCU; use HKLM explicitly)
  --protocol https   Protocol value name: https, http, or *  (default: https)
  --zone 2           Zone id: 1 intranet, 2 trusted, 3 internet, 4 restricted
  --dry-run          Print actions; do not write the registry
  --json             Machine-readable stdout for list/seed/denylist/doctor
  --help, -h
  --version, -V

Exit codes: 0 ok, 1 error, 2 usage, 3 need elevation for HKLM, 4 denylisted host.

Firefox does not honor this map. Edge and Chrome do via Attachment Manager.
`;

struct Options
{
    string command;
    string host;
    bool hiveExplicit;
    bool wantHkcu;
    bool wantHklm;
    bool dryRun;
    bool json;
    string protocol = "https";
    uint zoneId = 2;
    bool help;
    bool versionWanted;
}

int run(string[] args)
{
    try
    {
        auto opt = parseArgs(args);
        if (opt.help || opt.command == "help" || opt.command == "--help")
        {
            stdout.write(helpText);
            return Exit.ok;
        }
        if (opt.versionWanted || opt.command == "version")
        {
            stdout.writefln("%s %s (%s)", appName, appVersion, buildId);
            return Exit.ok;
        }
        if (opt.command.length == 0)
        {
            stderr.write(helpText);
            return Exit.usage;
        }
        validateProtocol(opt.protocol);
        if (opt.zoneId < 1 || opt.zoneId > 4)
            throw new ZoneOutException("--zone must be 1, 2, 3, or 4.", Exit.usage);

        version (Windows)
        {
            return dispatch(opt);
        }
        else
        {
            stderr.writeln("zone-out is Windows-only.");
            return Exit.error;
        }
    }
    catch (ZoneOutException e)
    {
        stderr.writeln(e.msg);
        return e.exitCode;
    }
    catch (Exception e)
    {
        stderr.writeln(e.msg);
        return Exit.error;
    }
}

private void validateProtocol(string protocol)
{
    auto p = protocol.toLower;
    if (p != "https" && p != "http" && p != "*")
        throw new ZoneOutException("--protocol must be https, http, or *.", Exit.usage);
}

private Options parseArgs(string[] args)
{
    Options opt;
    string[] positional;
    for (size_t i = 1; i < args.length; i++)
    {
        auto a = args[i];
        if (a == "--help" || a == "-h")
        {
            opt.help = true;
            continue;
        }
        if (a == "--version" || a == "-V")
        {
            opt.versionWanted = true;
            continue;
        }
        if (a == "--dry-run")
        {
            opt.dryRun = true;
            continue;
        }
        if (a == "--json")
        {
            opt.json = true;
            continue;
        }
        if (a == "--hive" || a.startsWith("--hive="))
        {
            string val;
            if (a.startsWith("--hive="))
                val = a["--hive=".length .. $];
            else
            {
                if (i + 1 >= args.length)
                    throw new ZoneOutException("--hive needs hklm or hkcu.", Exit.usage);
                val = args[++i];
            }
            applyHive(opt, val);
            continue;
        }
        if (a == "--protocol" || a.startsWith("--protocol="))
        {
            if (a.startsWith("--protocol="))
                opt.protocol = a["--protocol=".length .. $];
            else
            {
                if (i + 1 >= args.length)
                    throw new ZoneOutException("--protocol needs a value.", Exit.usage);
                opt.protocol = args[++i];
            }
            continue;
        }
        if (a == "--zone" || a.startsWith("--zone="))
        {
            string val;
            if (a.startsWith("--zone="))
                val = a["--zone=".length .. $];
            else
            {
                if (i + 1 >= args.length)
                    throw new ZoneOutException("--zone needs 1-4.", Exit.usage);
                val = args[++i];
            }
            opt.zoneId = to!uint(val);
            continue;
        }
        if (a.startsWith("-"))
            throw new ZoneOutException("Unknown option: " ~ a, Exit.usage);
        positional ~= a;
    }
    if (positional.length)
        opt.command = positional[0].toLower;
    if (positional.length > 1)
        opt.host = positional[1];
    if (positional.length > 2)
        throw new ZoneOutException("Too many arguments. See zone-out --help.", Exit.usage);
    return opt;
}

private void applyHive(ref Options opt, string val)
{
    auto v = val.toLower;
    opt.hiveExplicit = true;
    if (v == "hklm" || v == "hkml" || v == "machine" || v == "lm")
        opt.wantHklm = true;
    else if (v == "hkcu" || v == "user" || v == "cu")
        opt.wantHkcu = true;
    else if (v == "both")
    {
        opt.wantHklm = true;
        opt.wantHkcu = true;
    }
    else
        throw new ZoneOutException("--hive must be hklm, hkcu, or both.", Exit.usage);
}

version (Windows)
{
    private ZoneHive[] selectedHives(const ref Options opt, bool forWrite)
    {
        ZoneHive[] hives;
        if (opt.hiveExplicit)
        {
            if (opt.wantHkcu)
                hives ~= ZoneHive.hkcu;
            if (opt.wantHklm)
                hives ~= ZoneHive.hklm;
            return hives;
        }
        if (forWrite)
            return [ZoneHive.hkcu];
        // list/doctor: show both when possible
        hives ~= ZoneHive.hkcu;
        hives ~= ZoneHive.hklm;
        return hives;
    }

    private int dispatch(Options opt)
    {
        auto psl = parsePsl(import("public-suffix-list.dat"));
        switch (opt.command)
        {
        case "apply":
            return cmdApply(opt, psl);
        case "add":
            return cmdAdd(opt, psl);
        case "remove":
        case "rm":
            return cmdRemove(opt, psl);
        case "list":
        case "ls":
            return cmdList(opt);
        case "seed":
            return cmdPrintList(opt, bundledSeed(), "seed");
        case "denylist":
        case "deny":
            return cmdPrintList(opt, bundledDenylist(), "denylist");
        case "doctor":
        case "debug-dump":
        case "debug_dump":
            return cmdDoctor(opt);
        default:
            throw new ZoneOutException("Unknown command: " ~ opt.command ~ ". See zone-out --help.", Exit.usage);
        }
    }

    private int cmdApply(Options opt, PublicSuffixList psl)
    {
        auto hives = selectedHives(opt, true);
        auto deny = bundledDenylist();
        auto seed = bundledSeed();
        int written;
        int skipped;
        foreach (host; seed)
        {
            if (isDenied(host, deny))
            {
                skipped++;
                stderr.writefln("skip denylisted seed: %s", host);
                continue;
            }
            auto split = splitForZoneMap(psl, host);
            foreach (hive; hives)
            {
                writeZone(hive, split, opt.protocol, opt.zoneId, opt.dryRun);
                written++;
                auto prefix = opt.dryRun ? "dry-run" : "wrote";
                stderr.writefln("%s %s %s (%s) %s=%s", prefix, hiveName(hive), split.host,
                    split.leftover.length ? split.apex ~ `\` ~ split.leftover : split.apex,
                    opt.protocol, opt.zoneId);
            }
        }
        stderr.writefln("%s %s host-hive writes, %s seed rows skipped.",
            opt.dryRun ? "Would apply" : "Applied", written, skipped);
        return Exit.ok;
    }

    private int cmdAdd(Options opt, PublicSuffixList psl)
    {
        if (opt.host.length == 0)
            throw new ZoneOutException("add requires a host. Example: zone-out add grok.com", Exit.usage);
        auto split = splitForZoneMap(psl, opt.host);
        if (split.host.length == 0 || split.apex.length == 0)
            throw new ZoneOutException("Not a registrable host: " ~ opt.host, Exit.error);
        if (isDenied(split.host) || isDenied(split.apex))
        {
            throw new ZoneOutException(
                split.host ~ " is on the denylist (UGC / object storage). MotW stays on.",
                Exit.denied);
        }
        foreach (hive; selectedHives(opt, true))
        {
            writeZone(hive, split, opt.protocol, opt.zoneId, opt.dryRun);
            stderr.writefln("%s %s %s", opt.dryRun ? "dry-run" : "wrote", hiveName(hive), split.host);
        }
        return Exit.ok;
    }

    private int cmdRemove(Options opt, PublicSuffixList psl)
    {
        if (opt.host.length == 0)
            throw new ZoneOutException("remove requires a host.", Exit.usage);
        auto split = splitForZoneMap(psl, opt.host);
        if (split.apex.length == 0)
            throw new ZoneOutException("Not a registrable host: " ~ opt.host, Exit.error);
        foreach (hive; selectedHives(opt, true))
        {
            removeZone(hive, split, opt.protocol, opt.dryRun);
            stderr.writefln("%s %s %s", opt.dryRun ? "dry-run remove" : "removed", hiveName(hive), split.host);
        }
        return Exit.ok;
    }

    private int cmdList(Options opt)
    {
        ZoneEntry[] all;
        foreach (hive; selectedHives(opt, false))
        {
            try
                all ~= listZones(hive);
            catch (ZoneOutException e)
            {
                if (hive == ZoneHive.hklm)
                    stderr.writefln("note: skipping HKLM (%s)", e.msg);
                else
                    throw e;
            }
        }
        if (opt.json)
        {
            JSONValue[] arr;
            foreach (e; all)
            {
                arr ~= JSONValue([
                    "hive": JSONValue(hiveName(e.hive)),
                    "host": JSONValue(e.host),
                    "key": JSONValue(e.keyPath),
                    "protocol": JSONValue(e.protocol),
                    "zone": JSONValue(e.zoneId),
                ]);
            }
            stdout.writeln(JSONValue(arr).toString);
            return Exit.ok;
        }
        if (all.length == 0)
        {
            stderr.writeln("No Zone Map domain entries found.");
            return Exit.ok;
        }
        foreach (e; all)
            stdout.writefln("%s\t%s\t%s=%s", hiveName(e.hive), e.host, e.protocol, e.zoneId);
        return Exit.ok;
    }

    private int cmdPrintList(Options opt, string[] hosts, string kind)
    {
        if (opt.json)
        {
            JSONValue[] arr;
            foreach (h; hosts)
                arr ~= JSONValue(h);
            stdout.writeln(JSONValue(["kind": JSONValue(kind), "domains": JSONValue(arr)]).toString);
            return Exit.ok;
        }
        foreach (h; hosts)
            stdout.writeln(h);
        return Exit.ok;
    }

    private int cmdDoctor(Options opt)
    {
        auto policy = readHklmOnlyPolicy();
        JSONValue obj = [
            "name": JSONValue(appName),
            "version": JSONValue(appVersion),
            "build": JSONValue(buildId),
            "license": JSONValue(licenseId),
            "os": JSONValue("windows"),
            "elevated": JSONValue(isElevated()),
            "hklm_only_policy": JSONValue(policy.hklmOnly),
            "hklm_only_readable": JSONValue(policy.hklmOnlyReadable),
            "seed_count": JSONValue(cast(int) bundledSeed().length),
            "denylist_count": JSONValue(cast(int) bundledDenylist().length),
            "default_write_hive": JSONValue("HKCU"),
        ];
        size_t hkcuN, hklmN;
        try
            hkcuN = listZones(ZoneHive.hkcu).length;
        catch (Exception)
        {
        }
        try
            hklmN = listZones(ZoneHive.hklm).length;
        catch (Exception)
        {
        }
        obj["hkcu_entries"] = JSONValue(cast(int) hkcuN);
        obj["hklm_entries"] = JSONValue(cast(int) hklmN);

        if (opt.json)
        {
            stdout.writeln(obj.toString);
            return Exit.ok;
        }
        stdout.writefln("name: %s", appName);
        stdout.writefln("version: %s (%s)", appVersion, buildId);
        stdout.writefln("license: %s", licenseId);
        stdout.writefln("os: windows");
        stdout.writefln("elevated: %s", isElevated());
        stdout.writefln("default write hive: %s", "HKCU");
        stdout.writefln("policy Security_HKLM_only: %s (readable=%s)", policy.hklmOnly, policy.hklmOnlyReadable);
        stdout.writefln("seed domains: %s", bundledSeed().length);
        stdout.writefln("denylist domains: %s", bundledDenylist().length);
        stdout.writefln("HKCU ZoneMap entries: %s", hkcuN);
        stdout.writefln("HKLM ZoneMap entries: %s", hklmN);
        stdout.writeln("secrets: none (this dump does not read browser history or tokens)");
        return Exit.ok;
    }
}
